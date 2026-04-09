// lib/services/smart_search_service.dart
//
// ALGO FIX (parallelise adjacent cells): _searchAdjacentCells previously
// awaited each cell lookup + search sequentially inside a for-loop.
// Each REST round-trip adds ~100–300 ms. For a typical cell with 8
// neighbours that's up to 2.4 s of serial latency that can be fully
// parallelised. Replaced with Future.wait.
//
// ALGO FIX (parallelise neighboring wilayas): _searchNeighboringWilayas
// previously awaited each wilaya search sequentially in a for-loop.
// With N neighboring wilayas (typically 4–8), that was 400–2400 ms of
// pure serial latency. Replaced with Future.wait — wall-clock time now
// determined by the single slowest wilaya fetch, not their sum.
//
// ALGO FIX (composite score): _sortAndLimit previously sorted by distance
// only, ignoring rating entirely. Replaced with RankingUtils.workerScore
// (rating 40% + distance 35% + response rate 15% + recency 10%).
//
// ALGO FIX (A5): _sortAndLimit now passes a.data.ratingCount as reviewCount
// to RankingUtils.workerScore() so the cold-start fallback activates for new
// workers (reviewCount == 0) instead of suppressing them with a zero rating.

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/worker_model.dart';
import '../models/search_context.dart';
import '../models/search_result_model.dart';
import '../models/geographic_cell.dart';
import '../utils/model_extensions.dart';
import '../utils/ranking_utils.dart';
import 'api_service.dart';
import 'geographic_grid_service.dart';
import 'wilaya_manager.dart';
import 'smart_search_service_interface.dart';

class SmartSearchException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  SmartSearchException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'SmartSearchException: $message${code != null ? ' (Code: $code)' : ''}';
}

class SmartSearchService implements SmartSearchServiceInterface {
  static const int defaultMaxResults = 20;
  static const int minMaxResults = 1;
  static const int maxMaxResults = 100;
  static const double defaultMaxRadius = 50.0;
  static const double minMaxRadius = 1.0;
  static const double maxMaxRadius = 500.0;
  static const Duration searchTimeout = Duration(seconds: 30);
  static const Duration cacheExpiration = Duration(minutes: 5);
  static const int maxCacheSize = 50;
  static const Duration minSearchInterval = Duration(seconds: 1);

  final ApiService firestoreService;
  final GeographicGridService geographicGridService;
  final WilayaManager wilayaManager;

  final Map<String, _CachedSearchResult> _searchCache = {};
  DateTime? _lastSearchTime;
  bool _isDisposed = false;
  int _searchCount = 0;

  SmartSearchService(
    this.firestoreService,
    this.geographicGridService,
    this.wilayaManager,
  );

  bool get isDisposed => _isDisposed;
  int get searchCount => _searchCount;

  Future<List<GeoSearchResult<WorkerModel>>> searchWorkers({
    required double userLat,
    required double userLng,
    required int userWilayaCode,
    required String serviceType,
    int maxResults = defaultMaxResults,
    double maxRadius = defaultMaxRadius,
    bool useCache = true,
  }) async {
    _ensureNotDisposed();
    _validateSearchInput(
      userLat: userLat,
      userLng: userLng,
      userWilayaCode: userWilayaCode,
      serviceType: serviceType,
      maxResults: maxResults,
      maxRadius: maxRadius,
    );

    final cacheKey = _generateCacheKey(
      userLat,
      userLng,
      userWilayaCode,
      serviceType,
      maxResults,
      maxRadius,
    );

    if (useCache) {
      final cached = _getFromCache(cacheKey);
      if (cached != null) {
        _logInfo('Cache hit for search: $serviceType');
        return cached;
      }
    }

    try {
      await _enforceRateLimit();
      _searchCount++;

      _logInfo(
        'Searching workers: serviceType=$serviceType, '
        'location=($userLat, $userLng), '
        'wilaya=$userWilayaCode, '
        'maxResults=$maxResults, '
        'maxRadius=${maxRadius}km',
      );

      final results = await _performSearch(
        userLat: userLat,
        userLng: userLng,
        userWilayaCode: userWilayaCode,
        serviceType: serviceType,
        maxResults: maxResults,
        maxRadius: maxRadius,
      ).timeout(searchTimeout);

      _cacheResults(cacheKey, results);
      _logInfo('Search completed: found ${results.length} workers');

      return results;
    } on TimeoutException {
      throw SmartSearchException(
        'Search timed out',
        code: 'SEARCH_TIMEOUT',
      );
    } catch (e) {
      _logError('searchWorkers', e);
      if (e is SmartSearchException) rethrow;
      throw SmartSearchException(
        'Failed to search workers',
        code: 'SEARCH_ERROR',
        originalError: e,
      );
    }
  }

  Future<List<GeoSearchResult<WorkerModel>>> _performSearch({
    required double userLat,
    required double userLng,
    required int userWilayaCode,
    required String serviceType,
    required int maxResults,
    required double maxRadius,
  }) async {
    final currentCell = await geographicGridService.getCellForLocation(
      userLat,
      userLng,
      userWilayaCode,
    );

    if (currentCell == null) {
      throw SmartSearchException(
        'Could not determine geographic cell for location',
        code: 'CELL_NOT_FOUND',
      );
    }

    final context = SearchContext(
      userLat: userLat,
      userLng: userLng,
      userWilayaCode: userWilayaCode,
      currentCellId: currentCell.id,
      maxRadius: maxRadius,
      maxResults: maxResults,
    );

    final results = <GeoSearchResult<WorkerModel>>[];

    // Stage 1+2 remain parallel (unchanged from previous refactor).
    final parallelResults =
        await Future.wait<List<GeoSearchResult<WorkerModel>>>([
      _searchInCell(currentCell, serviceType, context),
      _searchAdjacentCells(currentCell, serviceType, context),
    ]);
    results.addAll(parallelResults[0]);
    results.addAll(parallelResults[1]);

    if (results.length >= maxResults) {
      return _sortAndLimit(results, context);
    }

    results.addAll(await _searchSameWilaya(serviceType, context));
    if (results.length >= maxResults) {
      return _sortAndLimit(results, context);
    }

    results.addAll(await _searchNeighboringWilayas(serviceType, context));

    return _sortAndLimit(results, context);
  }

  Future<List<GeoSearchResult<WorkerModel>>> _searchInCell(
    GeographicCell cell,
    String serviceType,
    SearchContext context,
  ) async {
    if (context.searchedCellIds.contains(cell.id)) {
      return [];
    }

    try {
      _logInfo('Searching in cell: ${cell.id}');

      final workers = await firestoreService.getWorkersInCell(
        cellId: cell.id,
        serviceType: serviceType,
        onlineOnly: true,
      );

      context.searchedCellIds.add(cell.id);

      final results = workers
          .map((worker) {
            final distance = worker.distanceTo(context.userLat, context.userLng);

            return GeoSearchResult<WorkerModel>(
              data: worker,
              distance: distance,
              cellId: cell.id,
              wilayaCode: cell.wilayaCode,
              source: SearchResultSource.currentCell,
            );
          })
          .where((result) => result.distance <= context.maxRadius)
          .toList();

      _logInfo('Found ${results.length} workers in cell ${cell.id}');
      return results;
    } catch (e) {
      _logWarning('Error searching in cell ${cell.id}: $e');
      return [];
    }
  }

  /// FIX: replaced sequential for-loop with Future.wait to parallelise all
  /// adjacent cell lookups + searches.
  Future<List<GeoSearchResult<WorkerModel>>> _searchAdjacentCells(
    GeographicCell currentCell,
    String serviceType,
    SearchContext context,
  ) async {
    final uncheckedIds = currentCell.adjacentCellIds
        .where((id) => !context.searchedCellIds.contains(id))
        .toList();

    if (uncheckedIds.isEmpty) return [];

    _logInfo('Searching ${uncheckedIds.length} adjacent cells (parallel)');

    final perCellResults = await Future.wait<List<GeoSearchResult<WorkerModel>>>(
      uncheckedIds.map((adjacentCellId) async {
        try {
          final cell = await geographicGridService.getCell(adjacentCellId);
          if (cell == null) {
            _logWarning('Adjacent cell not found: $adjacentCellId');
            return <GeoSearchResult<WorkerModel>>[];
          }
          final cellResults = await _searchInCell(cell, serviceType, context);
          return cellResults
              .map((r) => GeoSearchResult<WorkerModel>(
                    data:       r.data,
                    distance:   r.distance,
                    cellId:     r.cellId,
                    wilayaCode: r.wilayaCode,
                    source:     SearchResultSource.adjacentCell,
                  ))
              .toList();
        } catch (e) {
          _logWarning('Error searching adjacent cell $adjacentCellId: $e');
          return <GeoSearchResult<WorkerModel>>[];
        }
      }),
    );

    final results = perCellResults.expand((r) => r).toList();
    _logInfo('Found ${results.length} workers in adjacent cells');
    return results;
  }

  Future<List<GeoSearchResult<WorkerModel>>> _searchSameWilaya(
    String serviceType,
    SearchContext context,
  ) async {
    if (context.searchedWilayaCodes.contains(context.userWilayaCode)) {
      return [];
    }

    try {
      _logInfo('Searching same wilaya: ${context.userWilayaCode}');

      final workers = await firestoreService.getWorkersInWilaya(
        wilayaCode: context.userWilayaCode,
        serviceType: serviceType,
        onlineOnly: true,
      );

      context.searchedWilayaCodes.add(context.userWilayaCode);

      final results = workers
          .where((worker) => !context.searchedCellIds.contains(worker.cellId))
          .map((worker) {
            final distance = worker.distanceTo(context.userLat, context.userLng);

            return GeoSearchResult<WorkerModel>(
              data: worker,
              distance: distance,
              cellId: worker.cellId ?? '',
              wilayaCode: worker.wilayaCode ?? context.userWilayaCode,
              source: SearchResultSource.sameWilaya,
            );
          })
          .where((result) => result.distance <= context.maxRadius)
          .toList();

      _logInfo('Found ${results.length} workers in same wilaya');
      return results;
    } catch (e) {
      _logWarning('Error searching same wilaya: $e');
      return [];
    }
  }

  /// FIX (A1): replaced sequential for-loop with Future.wait to parallelise
  /// all neighboring wilaya searches.
  /// FIX: explicit generic type on Future.wait to prevent List<dynamic> inference.
  Future<List<GeoSearchResult<WorkerModel>>> _searchNeighboringWilayas(
    String serviceType,
    SearchContext context,
  ) async {
    final neighboringWilayas =
        wilayaManager.getNeighboringWilayas(context.userWilayaCode);

    final unchecked = neighboringWilayas
        .where((w) => !context.searchedWilayaCodes.contains(w.code))
        .toList();

    if (unchecked.isEmpty) return [];

    _logInfo('Searching ${unchecked.length} neighboring wilayas (parallel)');

    // FIX: explicit Future.wait<List<GeoSearchResult<WorkerModel>>> prevents
    // the compiler from inferring List<dynamic> for the expand result.
    final perWilayaResults = await Future.wait<List<GeoSearchResult<WorkerModel>>>(
      unchecked.map((wilaya) async {
        try {
          final workers = await firestoreService.getWorkersInWilaya(
            wilayaCode: wilaya.code,
            serviceType: serviceType,
            onlineOnly: true,
          );

          context.searchedWilayaCodes.add(wilaya.code);

          return workers
              .map((worker) {
                final distance =
                    worker.distanceTo(context.userLat, context.userLng);

                return GeoSearchResult<WorkerModel>(
                  data: worker,
                  distance: distance,
                  cellId: worker.cellId ?? '',
                  wilayaCode: worker.wilayaCode ?? wilaya.code,
                  source: SearchResultSource.neighboringWilaya,
                );
              })
              .where((result) => result.distance <= context.maxRadius)
              .toList();
        } catch (e) {
          _logWarning('Error searching wilaya ${wilaya.code}: $e');
          return <GeoSearchResult<WorkerModel>>[];
        }
      }),
    );

    final List<GeoSearchResult<WorkerModel>> results =
        perWilayaResults.expand((r) => r).toList();
    _logInfo('Found ${results.length} workers in neighboring wilayas');
    return results;
  }

  /// FIX: replaced pure distance sort with composite score ranking.
  /// FIX (A5): pass reviewCount for cold-start guard.
  List<GeoSearchResult<WorkerModel>> _sortAndLimit(
    List<GeoSearchResult<WorkerModel>> results,
    SearchContext context,
  ) {
    final seen   = <String>{};
    final unique = results.where((result) {
      if (seen.contains(result.data.id)) return false;
      seen.add(result.data.id);
      return true;
    }).toList();

    unique.sort((a, b) {
      final scoreA = RankingUtils.workerScore(
        bayesianRatingValue: a.data.averageRating,
        distanceKm:          a.distance,
        reviewCount:         a.data.ratingCount,
        responseRate:        a.data.responseRate,
        daysSinceActive:     a.data.daysSinceActive,
      );
      final scoreB = RankingUtils.workerScore(
        bayesianRatingValue: b.data.averageRating,
        distanceKm:          b.distance,
        reviewCount:         b.data.ratingCount,
        responseRate:        b.data.responseRate,
        daysSinceActive:     b.data.daysSinceActive,
      );
      return scoreB.compareTo(scoreA);
    });

    return unique.take(context.maxResults).toList();
  }

  Future<WorkerModel?> findNearestWorker({
    required double userLat,
    required double userLng,
    required int userWilayaCode,
    required String serviceType,
    double maxRadius = defaultMaxRadius,
  }) async {
    _ensureNotDisposed();

    try {
      _logInfo('Finding nearest worker: $serviceType');

      final results = await searchWorkers(
        userLat: userLat,
        userLng: userLng,
        userWilayaCode: userWilayaCode,
        serviceType: serviceType,
        maxResults: 1,
        maxRadius: maxRadius,
      );

      if (results.isEmpty) {
        _logInfo('No workers found for service type: $serviceType');
        return null;
      }

      final nearest = results.first;
      _logInfo(
        'Nearest worker found: ${nearest.data.name} '
        'at ${nearest.distance.toStringAsFixed(2)}km',
      );

      return nearest.data;
    } catch (e) {
      _logError('findNearestWorker', e);
      if (e is SmartSearchException) rethrow;
      throw SmartSearchException(
        'Failed to find nearest worker',
        code: 'NEAREST_WORKER_ERROR',
        originalError: e,
      );
    }
  }

  Future<List<WorkerModel>> getOnlineWorkersInWilaya({
    required int wilayaCode,
    String? serviceType,
  }) async {
    _ensureNotDisposed();
    _validateWilayaCode(wilayaCode);

    try {
      _logInfo('Getting online workers in wilaya: $wilayaCode');

      final workers = await firestoreService.getWorkersInWilaya(
        wilayaCode: wilayaCode,
        serviceType: serviceType,
        onlineOnly: true,
      );

      _logInfo('Found ${workers.length} online workers in wilaya $wilayaCode');
      return workers;
    } catch (e) {
      _logError('getOnlineWorkersInWilaya', e);
      if (e is SmartSearchException) rethrow;
      throw SmartSearchException(
        'Failed to get online workers',
        code: 'GET_WORKERS_ERROR',
        originalError: e,
      );
    }
  }

  void _validateSearchInput({
    required double userLat,
    required double userLng,
    required int userWilayaCode,
    required String serviceType,
    required int maxResults,
    required double maxRadius,
  }) {
    if (userLat < -90 || userLat > 90) {
      throw SmartSearchException(
        'Invalid latitude: $userLat (must be between -90 and 90)',
        code: 'INVALID_LATITUDE',
      );
    }

    if (userLng < -180 || userLng > 180) {
      throw SmartSearchException(
        'Invalid longitude: $userLng (must be between -180 and 180)',
        code: 'INVALID_LONGITUDE',
      );
    }

    _validateWilayaCode(userWilayaCode);

    if (serviceType.trim().isEmpty) {
      throw SmartSearchException(
        'Service type cannot be empty',
        code: 'INVALID_SERVICE_TYPE',
      );
    }

    if (maxResults < minMaxResults || maxResults > maxMaxResults) {
      throw SmartSearchException(
        'Invalid maxResults: $maxResults (must be between $minMaxResults and $maxMaxResults)',
        code: 'INVALID_MAX_RESULTS',
      );
    }

    if (maxRadius < minMaxRadius || maxRadius > maxMaxRadius) {
      throw SmartSearchException(
        'Invalid maxRadius: $maxRadius (must be between $minMaxRadius and $maxMaxRadius km)',
        code: 'INVALID_MAX_RADIUS',
      );
    }
  }

  void _validateWilayaCode(int wilayaCode) {
    if (wilayaCode < 1 || wilayaCode > 58) {
      throw SmartSearchException(
        'Invalid wilaya code: $wilayaCode (must be between 1 and 58)',
        code: 'INVALID_WILAYA_CODE',
      );
    }
  }

  Future<void> _enforceRateLimit() async {
    if (_lastSearchTime != null) {
      final timeSinceLastSearch =
          DateTime.now().difference(_lastSearchTime!);

      if (timeSinceLastSearch < minSearchInterval) {
        final delay = minSearchInterval - timeSinceLastSearch;
        _logInfo('Rate limiting: waiting ${delay.inMilliseconds}ms');
        await Future.delayed(delay);
      }
    }

    _lastSearchTime = DateTime.now();
  }

  String _generateCacheKey(
    double userLat,
    double userLng,
    int userWilayaCode,
    String serviceType,
    int maxResults,
    double maxRadius,
  ) {
    final roundedLat = (userLat * 1000).round() / 1000;
    final roundedLng = (userLng * 1000).round() / 1000;

    return '$serviceType:$userWilayaCode:$roundedLat,$roundedLng:$maxResults:$maxRadius';
  }

  List<GeoSearchResult<WorkerModel>>? _getFromCache(String cacheKey) {
    final cached = _searchCache[cacheKey];

    if (cached == null) return null;

    if (cached.isExpired) {
      _searchCache.remove(cacheKey);
      return null;
    }

    return cached.results;
  }

  void _cacheResults(
      String cacheKey, List<GeoSearchResult<WorkerModel>> results) {
    if (_searchCache.length >= maxCacheSize) {
      _evictOldestCacheEntry();
    }

    _searchCache[cacheKey] = _CachedSearchResult(results);
  }

  void _evictOldestCacheEntry() {
    if (_searchCache.isEmpty) return;

    String? oldestKey;
    DateTime? oldestTime;

    for (final entry in _searchCache.entries) {
      if (oldestTime == null ||
          entry.value.cachedAt.isBefore(oldestTime)) {
        oldestKey = entry.key;
        oldestTime = entry.value.cachedAt;
      }
    }

    if (oldestKey != null) {
      _searchCache.remove(oldestKey);
    }
  }

  void clearCache() {
    _searchCache.clear();
    _logInfo('Search cache cleared');
  }

  void resetSearchCount() {
    _searchCount = 0;
    _logInfo('Search count reset');
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw SmartSearchException(
        'SmartSearchService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[SmartSearchService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[SmartSearchService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[SmartSearchService] ERROR in $method: $error');
    }
  }

  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    _searchCache.clear();
    _lastSearchTime = null;
    _searchCount = 0;
    _logInfo('SmartSearchService disposed');
  }
}

class _CachedSearchResult {
  final List<GeoSearchResult<WorkerModel>> results;
  final DateTime cachedAt;

  _CachedSearchResult(this.results) : cachedAt = DateTime.now();

  bool get isExpired {
    final now = DateTime.now();
    return now.difference(cachedAt) > SmartSearchService.cacheExpiration;
  }
}
