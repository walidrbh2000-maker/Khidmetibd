// lib/services/geographic_grid_service.dart

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/geographic_cell.dart';
import '../models/wilaya_model.dart';
import '../utils/model_extensions.dart';
import '../utils/geo_cell_utils.dart';
import 'api_service.dart';
import 'wilaya_manager.dart';
import 'geographic_grid_service_interface.dart';

class GeographicGridServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  GeographicGridServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'GeographicGridServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class GeographicGridService implements GeographicGridServiceInterface {
  static const double defaultCellRadiusKm = 5.0;

  // FIX: cellPrecisionDegrees is the canonical cell step.
  // adjacentCellOffsetDegrees MUST equal cellPrecisionDegrees so that
  // neighbour cells are exactly one cell-width apart — not 5× the cell size.
  //
  // OLD: adjacentCellOffsetDegrees = 0.05  ← skipped ~4 cells between centre
  //      and the nearest generated neighbour ID (gap ≈ 5.5 km at Algeria latitudes).
  // NEW: adjacentCellOffsetDegrees = 0.01  ← matches cellPrecisionDegrees exactly.
  static const double cellPrecisionDegrees    = 0.01;
  static const double adjacentCellOffsetDegrees = 0.01; // FIX: was 0.05

  static const int    maxCacheSize       = 500;
  static const Duration cacheTTL         = Duration(hours: 24);
  static const double earthRadiusKm      = 6371.0;
  static const int    coordinateDecimalPlaces = 2;
  static const double maxSearchDistanceKm     = 100.0;

  // Geohash precision-6 ≈ 1.2 × 0.6 km — matches the ~5 km cell radius well.
  static const int geohashPrecision = 6;

  final ApiService firestoreService;
  final WilayaManager wilayaManager;

  final Map<String, _CachedCell> _cellsCache = {};
  bool _isDisposed = false;

  GeographicGridService(
    this.firestoreService,
    this.wilayaManager,
  );

  Future<GeographicCell?> getCellForLocation(
    double lat,
    double lng,
    int wilayaCode,
  ) async {
    _ensureNotDisposed();
    _validateCoordinates(lat, lng);
    _validateWilayaCode(wilayaCode);

    try {
      final cellId = _generateCellId(lat, lng, wilayaCode);

      final cached = _getCachedCell(cellId);
      if (cached != null) {
        _logInfo('Cache hit for cell: $cellId');
        return cached;
      }

      GeographicCell? cell = await firestoreService.getCell(cellId);

      if (cell == null) {
        cell = await _createNewCell(lat, lng, wilayaCode, cellId);
      }

      _cacheCell(cellId, cell);
      return cell;
    } catch (e) {
      _logError('getCellForLocation', e);
      if (e is GeographicGridServiceException) rethrow;
      throw GeographicGridServiceException(
        'Failed to get cell for location',
        code: 'GET_CELL_FAILED',
        originalError: e,
      );
    }
  }

  Future<GeographicCell?> getCell(String cellId) async {
    _ensureNotDisposed();
    
    if (cellId.trim().isEmpty) {
      throw GeographicGridServiceException(
        'Cell ID cannot be empty',
        code: 'INVALID_CELL_ID',
      );
    }

    final cached = _getCachedCell(cellId);
    if (cached != null) {
      return cached;
    }

    try {
      final cell = await firestoreService.getCell(cellId);
      if (cell != null) {
        _cacheCell(cellId, cell);
      }
      return cell;
    } catch (e) {
      _logError('getCell', e);
      if (e is GeographicGridServiceException) rethrow;
      throw GeographicGridServiceException(
        'Failed to get cell',
        code: 'GET_CELL_FAILED',
        originalError: e,
      );
    }
  }

  Future<List<GeographicCell>> getCellsInWilaya(int wilayaCode) async {
    _ensureNotDisposed();
    _validateWilayaCode(wilayaCode);

    try {
      final cells = await firestoreService.getCellsInWilaya(wilayaCode);

      for (final cell in cells) {
        _cacheCell(cell.id, cell);
      }

      _logInfo('Retrieved ${cells.length} cells for wilaya $wilayaCode');
      return cells;
    } catch (e) {
      _logError('getCellsInWilaya', e);
      if (e is GeographicGridServiceException) rethrow;
      throw GeographicGridServiceException(
        'Failed to get cells in wilaya',
        code: 'GET_CELLS_FAILED',
        originalError: e,
      );
    }
  }

  Future<void> assignWorkerToCell({
    required String workerId,
    required double latitude,
    required double longitude,
  }) async {
    _ensureNotDisposed();
    
    if (workerId.trim().isEmpty) {
      throw GeographicGridServiceException(
        'Worker ID cannot be empty',
        code: 'INVALID_WORKER_ID',
      );
    }

    _validateCoordinates(latitude, longitude);

    try {
      final wilayaCode = getWilayaCodeFromCoordinates(latitude, longitude);
      if (wilayaCode == null) {
        throw GeographicGridServiceException(
          'Could not determine wilaya for coordinates ($latitude, $longitude)',
          code: 'WILAYA_NOT_FOUND',
        );
      }

      final cell = await getCellForLocation(latitude, longitude, wilayaCode);
      if (cell == null) {
        throw GeographicGridServiceException(
          'Could not get cell for location',
          code: 'CELL_NOT_FOUND',
        );
      }

      // FIX: replaced fake coordinate-string hash with standard base32 geohash.
      final geoHash = GeoHashHelper.encode(latitude, longitude,
          precision: geohashPrecision);

      await firestoreService.updateWorkerLocation(
        workerId,
        latitude,
        longitude,
        cellId: cell.id,
        wilayaCode: wilayaCode,
        geoHash: geoHash,
      );

      _logInfo('Worker $workerId assigned to cell ${cell.id} in wilaya $wilayaCode');
    } catch (e) {
      _logError('assignWorkerToCell', e);
      if (e is GeographicGridServiceException) rethrow;
      throw GeographicGridServiceException(
        'Failed to assign worker to cell',
        code: 'ASSIGN_WORKER_FAILED',
        originalError: e,
      );
    }
  }

  int? getWilayaCodeFromCoordinates(double lat, double lng) {
    _validateCoordinates(lat, lng);

    if (wilayaManager.wilayas.isEmpty) {
      _logWarning('No wilayas available');
      return null;
    }

    double minDistance = double.infinity;
    int? closestWilaya;

    for (final wilaya in wilayaManager.wilayas.values) {
      final distance = _calculateHaversineDistance(
        lat,
        lng,
        wilaya.centerLat,
        wilaya.centerLng,
      );

      if (distance < minDistance) {
        minDistance = distance;
        closestWilaya = wilaya.code;
      }
    }

    if (minDistance > maxSearchDistanceKm) {
      _logWarning(
        'Closest wilaya is ${minDistance.toStringAsFixed(1)}km away (exceeds max: $maxSearchDistanceKm km)',
      );
    }

    return closestWilaya;
  }

  List<String> getAdjacentCellIds(String cellId) {
    if (cellId.trim().isEmpty) {
      return [];
    }

    try {
      final parts = cellId.split('_');
      if (parts.length != 3) {
        _logWarning('Invalid cell ID format: $cellId');
        return [];
      }

      final wilayaCode = int.parse(parts[0]);
      final lat = double.parse(parts[1]);
      final lng = double.parse(parts[2]);

      return GeoCellUtils.ringCellIds(
        centerLat:   lat,
        centerLng:   lng,
        wilayaCode:  wilayaCode,
        radiusSteps: 1,
      );
    } catch (e) {
      _logError('getAdjacentCellIds', e);
      return [];
    }
  }

  Future<GeographicCell> _createNewCell(
    double lat,
    double lng,
    int wilayaCode,
    String cellId,
  ) async {
    final cell = GeographicCell(
      id: cellId,
      wilayaCode: wilayaCode,
      centerLat: _roundCoordinate(lat),
      centerLng: _roundCoordinate(lng),
      radius: defaultCellRadiusKm,
      adjacentCellIds: GeoCellUtils.ringCellIds(
        centerLat:   lat,
        centerLng:   lng,
        wilayaCode:  wilayaCode,
        radiusSteps: 1,
      ),
    );

    await firestoreService.saveCell(cell);
    _logInfo('Created new cell: $cellId at (${cell.centerLat}, ${cell.centerLng})');

    return cell;
  }

  String _generateCellId(double lat, double lng, int wilayaCode) {
    final roundedLat = _roundCoordinate(lat);
    final roundedLng = _roundCoordinate(lng);
    return '${wilayaCode}_${roundedLat.toStringAsFixed(coordinateDecimalPlaces)}_${roundedLng.toStringAsFixed(coordinateDecimalPlaces)}';
  }

  double _roundCoordinate(double coordinate) {
    final multiplier = math.pow(10, coordinateDecimalPlaces);
    return (coordinate * multiplier).round() / multiplier;
  }

  List<String> _calculateAdjacentCellIds(
    double lat,
    double lng,
    int wilayaCode,
  ) {
    return GeoCellUtils.ringCellIds(
      centerLat:   lat,
      centerLng:   lng,
      wilayaCode:  wilayaCode,
      radiusSteps: 1,
    );
  }

  double _calculateHaversineDistance(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final dLat = _toRadians(lat2 - lat1);
    final dLng = _toRadians(lng2 - lng1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _toRadians(double degrees) {
    return degrees * math.pi / 180.0;
  }

  void _validateCoordinates(double lat, double lng) {
    if (!_isValidLatitude(lat)) {
      throw GeographicGridServiceException(
        'Invalid latitude: $lat (must be between -90 and 90)',
        code: 'INVALID_LATITUDE',
      );
    }

    if (!_isValidLongitude(lng)) {
      throw GeographicGridServiceException(
        'Invalid longitude: $lng (must be between -180 and 180)',
        code: 'INVALID_LONGITUDE',
      );
    }
  }

  bool _isValidLatitude(double lat) {
    return lat >= -90 && lat <= 90;
  }

  bool _isValidLongitude(double lng) {
    return lng >= -180 && lng <= 180;
  }

  void _validateWilayaCode(int wilayaCode) {
    if (wilayaCode < 1 || wilayaCode > 58) {
      throw GeographicGridServiceException(
        'Invalid wilaya code: $wilayaCode (must be between 1 and 58)',
        code: 'INVALID_WILAYA_CODE',
      );
    }

    if (!wilayaManager.wilayas.containsKey(wilayaCode)) {
      throw GeographicGridServiceException(
        'Wilaya not found: $wilayaCode',
        code: 'WILAYA_NOT_FOUND',
      );
    }
  }

  GeographicCell? _getCachedCell(String cellId) {
    final cached = _cellsCache[cellId];
    if (cached == null) return null;

    if (cached.isExpired) {
      _cellsCache.remove(cellId);
      return null;
    }

    return cached.cell;
  }

  void _cacheCell(String cellId, GeographicCell cell) {
    if (_cellsCache.length >= maxCacheSize) {
      _evictOldestCacheEntry();
    }

    _cellsCache[cellId] = _CachedCell(cell);
  }

  void _evictOldestCacheEntry() {
    if (_cellsCache.isEmpty) return;

    String? oldestKey;
    DateTime? oldestTime;

    for (final entry in _cellsCache.entries) {
      if (oldestTime == null || entry.value.cachedAt.isBefore(oldestTime)) {
        oldestKey = entry.key;
        oldestTime = entry.value.cachedAt;
      }
    }

    if (oldestKey != null) {
      _cellsCache.remove(oldestKey);
    }
  }

  void clearCache() {
    _cellsCache.clear();
    _logInfo('Cache cleared');
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw GeographicGridServiceException(
        'GeographicGridService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[GeographicGridService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[GeographicGridService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[GeographicGridService] ERROR in $method: $error');
    }
  }

  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    _cellsCache.clear();
    _logInfo('GeographicGridService disposed');
  }
}

class _CachedCell {
  final GeographicCell cell;
  final DateTime cachedAt;

  _CachedCell(this.cell) : cachedAt = DateTime.now();

  bool get isExpired {
    final now = DateTime.now();
    return now.difference(cachedAt) > GeographicGridService.cacheTTL;
  }
}
