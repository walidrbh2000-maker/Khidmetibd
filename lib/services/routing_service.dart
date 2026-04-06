// lib/services/routing_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/route_info.dart';

class RoutingServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  RoutingServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'RoutingServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class RoutingService {
  static const String defaultBaseUrl = 'https://router.project-osrm.org';
  static const Duration requestTimeout = Duration(seconds: 10);
  static const Duration minRequestInterval = Duration(seconds: 1);
  static const Duration cacheExpiration = Duration(hours: 1);
  static const int maxCacheSize = 100;
  static const int maxRetries = 3;
  static const Duration baseRetryDelay = Duration(seconds: 2);
  static const double minLatitude = -90.0;
  static const double maxLatitude = 90.0;
  static const double minLongitude = -180.0;
  static const double maxLongitude = 180.0;
  static const double maxReasonableDistanceKm = 10000.0;
  static const String profileDriving = 'driving';
  static const String profileWalking = 'foot';
  static const String profileCycling = 'bike';

  final String baseUrl;
  final String? apiKey;

  final Map<String, _CachedRoute> _routeCache = {};
  DateTime? _lastRequestTime;
  bool _isDisposed = false;

  RoutingService({
    this.baseUrl = defaultBaseUrl,
    this.apiKey,
  });

  bool get isDisposed => _isDisposed;

  Future<RouteInfo> getRoute({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    String profile = profileDriving,
    bool useCache = true,
  }) async {
    _ensureNotDisposed();
    _validateCoordinates(startLat, startLng, 'start');
    _validateCoordinates(endLat, endLng, 'end');
    _validateProfile(profile);

    final cacheKey = _generateCacheKey(
      startLat,
      startLng,
      endLat,
      endLng,
      profile,
    );

    if (useCache) {
      final cached = _getFromCache(cacheKey);
      if (cached != null) {
        _logInfo('Cache hit for route');
        return cached;
      }
    }

    return _retryOperation(() async {
      try {
        await _enforceRateLimit();

        final url = _buildRouteUrl(
          startLat: startLat,
          startLng: startLng,
          endLat: endLat,
          endLng: endLng,
          profile: profile,
        );

        _logInfo('Requesting route: ${_formatCoordinates(startLat, startLng)} → ${_formatCoordinates(endLat, endLng)}');

        final response = await http
            .get(url, headers: _buildHeaders())
            .timeout(requestTimeout);

        _validateResponse(response);

        final data = json.decode(response.body) as Map<String, dynamic>;
        final routeInfo = _parseRouteResponse(data);

        _validateRouteInfo(routeInfo);
        _cacheRoute(cacheKey, routeInfo);

        _logInfo('Route calculated: ${_formatDistance(routeInfo.distance)}, ${_formatDuration(routeInfo.duration)}');

        return routeInfo;
      } on TimeoutException {
        throw RoutingServiceException(
          'Route request timed out',
          code: 'REQUEST_TIMEOUT',
        );
      } on FormatException catch (e) {
        throw RoutingServiceException(
          'Invalid response format from routing API',
          code: 'INVALID_RESPONSE',
          originalError: e,
        );
      } catch (e) {
        _logError('getRoute', e);
        if (e is RoutingServiceException) rethrow;
        throw RoutingServiceException(
          'Failed to get route',
          code: 'ROUTE_ERROR',
          originalError: e,
        );
      }
    });
  }

  Future<Duration> getEstimatedTravelTime({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    String profile = profileDriving,
  }) async {
    _ensureNotDisposed();

    try {
      final route = await getRoute(
        startLat: startLat,
        startLng: startLng,
        endLat: endLat,
        endLng: endLng,
        profile: profile,
      );

      return Duration(seconds: route.duration.round());
    } catch (e) {
      _logError('getEstimatedTravelTime', e);
      if (e is RoutingServiceException) rethrow;
      throw RoutingServiceException(
        'Failed to calculate travel time',
        code: 'TRAVEL_TIME_ERROR',
        originalError: e,
      );
    }
  }

  Future<double> getDistance({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    String profile = profileDriving,
  }) async {
    _ensureNotDisposed();

    try {
      final route = await getRoute(
        startLat: startLat,
        startLng: startLng,
        endLat: endLat,
        endLng: endLng,
        profile: profile,
      );

      return route.distance;
    } catch (e) {
      _logError('getDistance', e);
      if (e is RoutingServiceException) rethrow;
      throw RoutingServiceException(
        'Failed to calculate distance',
        code: 'DISTANCE_ERROR',
        originalError: e,
      );
    }
  }

  Uri _buildRouteUrl({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    required String profile,
  }) {
    final coordinates = '$startLng,$startLat;$endLng,$endLat';
    final path = '/route/v1/$profile/$coordinates';
    
    final queryParams = <String, String>{
      'overview': 'false',
      'geometries': 'polyline',
      'steps': 'false',
      if (apiKey != null) 'access_token': apiKey!,
    };

    return Uri.parse(baseUrl).replace(
      path: path,
      queryParameters: queryParams,
    );
  }

  Map<String, String> _buildHeaders() {
    return {
      'User-Agent': 'ServiceApp/1.0',
      'Accept': 'application/json',
    };
  }

  void _validateResponse(http.Response response) {
    if (response.statusCode == 429) {
      throw RoutingServiceException(
        'Rate limit exceeded. Please wait before making more requests.',
        code: 'RATE_LIMIT_EXCEEDED',
      );
    }

    if (response.statusCode == 400) {
      throw RoutingServiceException(
        'Invalid request parameters',
        code: 'INVALID_REQUEST',
      );
    }

    if (response.statusCode == 404) {
      throw RoutingServiceException(
        'Routing endpoint not found',
        code: 'ENDPOINT_NOT_FOUND',
      );
    }

    if (response.statusCode != 200) {
      throw RoutingServiceException(
        'Routing API returned status ${response.statusCode}',
        code: 'API_ERROR',
      );
    }

    if (response.body.isEmpty) {
      throw RoutingServiceException(
        'Empty response from routing API',
        code: 'EMPTY_RESPONSE',
      );
    }
  }

  RouteInfo _parseRouteResponse(Map<String, dynamic> data) {
    final code = data['code'] as String?;
    
    if (code != 'Ok') {
      final message = data['message'] as String?;
      throw RoutingServiceException(
        'Routing API error: ${message ?? code ?? "unknown error"}',
        code: 'API_ERROR',
      );
    }

    final routes = data['routes'] as List<dynamic>?;
    
    if (routes == null || routes.isEmpty) {
      throw RoutingServiceException(
        'No route found between the given points',
        code: 'NO_ROUTE',
      );
    }

    final route = routes.first as Map<String, dynamic>;
    
    final distance = route['distance'];
    final duration = route['duration'];

    if (distance == null || duration == null) {
      throw RoutingServiceException(
        'Invalid route data: missing distance or duration',
        code: 'INVALID_ROUTE_DATA',
      );
    }

    return RouteInfo(
      distance: (distance as num).toDouble(),
      duration: (duration as num).toDouble(),
    );
  }

  void _validateRouteInfo(RouteInfo routeInfo) {
    if (routeInfo.distance < 0) {
      throw RoutingServiceException(
        'Invalid route distance: ${routeInfo.distance}',
        code: 'INVALID_DISTANCE',
      );
    }

    if (routeInfo.duration < 0) {
      throw RoutingServiceException(
        'Invalid route duration: ${routeInfo.duration}',
        code: 'INVALID_DURATION',
      );
    }

    final distanceKm = routeInfo.distance / 1000;
    if (distanceKm > maxReasonableDistanceKm) {
      _logWarning('Unusually long route: ${distanceKm.toStringAsFixed(1)} km');
    }
  }

  void _validateCoordinates(double lat, double lng, String label) {
    if (lat < minLatitude || lat > maxLatitude) {
      throw RoutingServiceException(
        'Invalid $label latitude: $lat (must be between $minLatitude and $maxLatitude)',
        code: 'INVALID_LATITUDE',
      );
    }

    if (lng < minLongitude || lng > maxLongitude) {
      throw RoutingServiceException(
        'Invalid $label longitude: $lng (must be between $minLongitude and $maxLongitude)',
        code: 'INVALID_LONGITUDE',
      );
    }
  }

  void _validateProfile(String profile) {
    const validProfiles = [profileDriving, profileWalking, profileCycling];
    
    if (!validProfiles.contains(profile)) {
      throw RoutingServiceException(
        'Invalid profile: $profile (must be one of: ${validProfiles.join(", ")})',
        code: 'INVALID_PROFILE',
      );
    }
  }

  Future<void> _enforceRateLimit() async {
    if (_lastRequestTime != null) {
      final timeSinceLastRequest = DateTime.now().difference(_lastRequestTime!);
      
      if (timeSinceLastRequest < minRequestInterval) {
        final delay = minRequestInterval - timeSinceLastRequest;
        _logInfo('Rate limiting: waiting ${delay.inMilliseconds}ms');
        await Future.delayed(delay);
      }
    }
    
    _lastRequestTime = DateTime.now();
  }

  Future<T> _retryOperation<T>(Future<T> Function() operation) async {
    int attempts = 0;

    while (attempts < maxRetries) {
      try {
        return await operation();
      } catch (e) {
        attempts++;

        if (e is RoutingServiceException && e.code == 'RATE_LIMIT_EXCEEDED') {
          rethrow;
        }

        if (e is RoutingServiceException && 
            (e.code == 'INVALID_LATITUDE' ||
             e.code == 'INVALID_LONGITUDE' ||
             e.code == 'INVALID_PROFILE' ||
             e.code == 'INVALID_REQUEST')) {
          rethrow;
        }

        if (attempts >= maxRetries) {
          rethrow;
        }

        final delay = baseRetryDelay * attempts;
        _logWarning('Retry $attempts/$maxRetries after ${delay.inSeconds}s');
        await Future.delayed(delay);
      }
    }

    throw RoutingServiceException(
      'Max retries exceeded',
      code: 'MAX_RETRIES_EXCEEDED',
    );
  }

  String _generateCacheKey(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
    String profile,
  ) {
    final roundedStartLat = (startLat * 1000).round() / 1000;
    final roundedStartLng = (startLng * 1000).round() / 1000;
    final roundedEndLat = (endLat * 1000).round() / 1000;
    final roundedEndLng = (endLng * 1000).round() / 1000;
    
    return '$profile:$roundedStartLat,$roundedStartLng->$roundedEndLat,$roundedEndLng';
  }

  RouteInfo? _getFromCache(String cacheKey) {
    final cached = _routeCache[cacheKey];
    
    if (cached == null) return null;
    
    if (cached.isExpired) {
      _routeCache.remove(cacheKey);
      return null;
    }
    
    return cached.routeInfo;
  }

  void _cacheRoute(String cacheKey, RouteInfo routeInfo) {
    if (_routeCache.length >= maxCacheSize) {
      _evictOldestCacheEntry();
    }
    
    _routeCache[cacheKey] = _CachedRoute(routeInfo);
  }

  void _evictOldestCacheEntry() {
    if (_routeCache.isEmpty) return;

    String? oldestKey;
    DateTime? oldestTime;

    for (final entry in _routeCache.entries) {
      if (oldestTime == null || entry.value.cachedAt.isBefore(oldestTime)) {
        oldestKey = entry.key;
        oldestTime = entry.value.cachedAt;
      }
    }

    if (oldestKey != null) {
      _routeCache.remove(oldestKey);
    }
  }

  void _cleanExpiredCache() {
    final expiredKeys = _routeCache.entries
        .where((entry) => entry.value.isExpired)
        .map((entry) => entry.key)
        .toList();

    for (final key in expiredKeys) {
      _routeCache.remove(key);
    }

    if (expiredKeys.isNotEmpty) {
      _logInfo('Cleaned ${expiredKeys.length} expired cache entries');
    }
  }

  String _formatCoordinates(double lat, double lng) {
    return '(${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)})';
  }

  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.toStringAsFixed(0)}m';
    }
    return '${(meters / 1000).toStringAsFixed(2)}km';
  }

  String _formatDuration(double seconds) {
    final duration = Duration(seconds: seconds.round());
    
    if (duration.inHours > 0) {
      final hours = duration.inHours;
      final minutes = duration.inMinutes.remainder(60);
      return '${hours}h ${minutes}min';
    }
    
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}min';
    }
    
    return '${duration.inSeconds}s';
  }

  void clearCache() {
    _routeCache.clear();
    _logInfo('Route cache cleared');
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw RoutingServiceException(
        'RoutingService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[RoutingService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[RoutingService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) debugPrint('[RoutingService] ERROR in $method: $error');
  }

  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    _routeCache.clear();
    _lastRequestTime = null;
    _logInfo('RoutingService disposed');
  }
}

class _CachedRoute {
  final RouteInfo routeInfo;
  final DateTime cachedAt;

  _CachedRoute(this.routeInfo) : cachedAt = DateTime.now();

  bool get isExpired {
    final now = DateTime.now();
    return now.difference(cachedAt) > RoutingService.cacheExpiration;
  }
}