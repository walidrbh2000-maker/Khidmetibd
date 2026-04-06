// lib/services/geocoding_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class GeocodingServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  GeocodingServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'GeocodingServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class GeocodingService {
  static const Duration requestTimeout = Duration(seconds: 10);
  static const Duration minRequestInterval = Duration(seconds: 1);
  static const int maxRetries = 3;
  static const Duration baseRetryDelay = Duration(seconds: 2);
  static const Duration cacheExpiration = Duration(hours: 24);
  static const int maxCacheSize = 100;
  static const String defaultUserAgent = 'ServiceApp/1.0';
  static const String nominatimBaseUrl = 'https://nominatim.openstreetmap.org';

  // FIX (QA P1): Error codes that should never be retried. Retrying these
  // wastes time: validation errors (INVALID_ADDRESS, bad coordinates) will
  // never succeed on a second attempt, and rate-limit / auth failures require
  // human intervention — not an automatic retry loop.
  //
  // Before this fix, any GeocodingServiceException (including INVALID_ADDRESS)
  // was retried up to 3 times with 2/4/6-second delays, adding up to 12+
  // seconds of artificial lag for a call that was doomed from the start.
  static const _nonRetryableCodes = {
    'INVALID_ADDRESS',
    'INVALID_COORDINATES',
    'INVALID_LATITUDE',
    'INVALID_LONGITUDE',
    'INVALID_RESPONSE',
    'RATE_LIMIT_EXCEEDED',
    'FORBIDDEN',
    'SERVICE_DISPOSED',
  };

  final String? nominatimApiKey;
  final String userAgent;

  final Map<String, _CachedGeocodingResult> _geocodingCache = {};
  final Map<String, _CachedGeocodingResult> _reverseGeocodingCache = {};
  DateTime? _lastRequestTime;
  bool _isDisposed = false;

  GeocodingService({
    this.nominatimApiKey,
    this.userAgent = defaultUserAgent,
  });

  Future<({double lat, double lng})?> getCoordinatesFromAddress(
    String address,
  ) async {
    _ensureNotDisposed();

    if (address.trim().isEmpty) {
      throw GeocodingServiceException(
        'Address cannot be empty',
        code: 'INVALID_ADDRESS',
      );
    }

    final normalizedAddress = _normalizeAddress(address);
    final cached = _getFromGeocodingCache(normalizedAddress);
    if (cached != null) {
      _logInfo('Cache hit for address: $normalizedAddress');
      return cached;
    }

    return _retryOperation(() async {
      try {
        await _enforceRateLimit();

        final encodedAddress = Uri.encodeComponent(normalizedAddress);
        final url = _buildSearchUrl(encodedAddress);

        _logInfo('Geocoding address: $normalizedAddress');
        final response = await http
            .get(url, headers: _buildHeaders())
            .timeout(requestTimeout);

        _validateResponse(response, 'Geocoding');

        final List<dynamic> data = json.decode(response.body);

        if (data.isEmpty) {
          _logWarning('No results found for address: $normalizedAddress');
          return null;
        }

        final location = data.first;
        final coordinates =
            _parseCoordinatesFromSearchResult(location);

        _cacheGeocodingResult(normalizedAddress, coordinates);
        _logInfo('Geocoded successfully: $normalizedAddress');

        return coordinates;
      } on TimeoutException {
        throw GeocodingServiceException(
          'Geocoding request timed out',
          code: 'TIMEOUT',
        );
      } on FormatException catch (e) {
        throw GeocodingServiceException(
          'Invalid response format',
          code: 'INVALID_RESPONSE',
          originalError: e,
        );
      } catch (e) {
        if (e is GeocodingServiceException) rethrow;
        throw GeocodingServiceException(
          'Error geocoding address',
          code: 'GEOCODING_ERROR',
          originalError: e,
        );
      }
    });
  }

  // FIX 2: Instead of returning the raw `display_name` string (which is the
  // full postal address, e.g. "3 Rue des Lilas, Belouizdad, Sidi M'Hamed,
  // Alger, 16002, Algérie"), parse the structured `address` object that
  // Nominatim always includes in /reverse responses and build a concise
  // "City, Neighbourhood" string instead.
  // Falls back to display_name only when the address object is absent.
  Future<String?> getAddressFromCoordinates({
    required double lat,
    required double lng,
  }) async {
    _ensureNotDisposed();
    _validateCoordinates(lat, lng);

    final cacheKey = _buildReverseGeocodingCacheKey(lat, lng);
    final cached = _getFromReverseGeocodingCache(cacheKey);
    if (cached != null) {
      _logInfo('Cache hit for coordinates: ($lat, $lng)');
      return cached;
    }

    return _retryOperation(() async {
      try {
        await _enforceRateLimit();

        final url = _buildReverseUrl(lat, lng);

        _logInfo('Reverse geocoding: ($lat, $lng)');
        final response = await http
            .get(url, headers: _buildHeaders())
            .timeout(requestTimeout);

        _validateResponse(response, 'Reverse geocoding');

        final data = json.decode(response.body) as Map<String, dynamic>;

        // ── FIX 2: Build a concise "City, Neighbourhood" string ──────────────
        // Nominatim /reverse always includes a structured `address` object.
        // Prefer it over `display_name` which is the full postal address
        // string and routinely breaks every UI widget that renders it.
        String? result;
        final addressObj = data['address'] as Map<String, dynamic>?;

        if (addressObj != null) {
          // City — check keys from most-specific to least-specific.
          final city = addressObj['city']    as String? ??
                       addressObj['town']    as String? ??
                       addressObj['village'] as String? ??
                       addressObj['state']   as String?;

          // Neighbourhood / sub-locality — same strategy.
          final neighbourhood = addressObj['suburb']        as String? ??
                                addressObj['neighbourhood'] as String? ??
                                addressObj['residential']   as String? ??
                                addressObj['county']        as String?;

          if (city != null && neighbourhood != null) {
            result = '$city, $neighbourhood';
          } else if (city != null) {
            result = city;
          } else if (neighbourhood != null) {
            result = neighbourhood;
          }
        }

        // Fallback: use display_name only when the address object is absent
        // or contained none of the expected keys.
        if (result == null || result.isEmpty) {
          result = data['display_name'] as String?;
        }

        if (result == null || result.isEmpty) {
          _logWarning('No address found for coordinates: ($lat, $lng)');
          return null;
        }

        _cacheReverseGeocodingResult(cacheKey, result);
        _logInfo('Reverse geocoded successfully: ($lat, $lng)');

        return result;
      } on TimeoutException {
        throw GeocodingServiceException(
          'Reverse geocoding request timed out',
          code: 'TIMEOUT',
        );
      } on FormatException catch (e) {
        throw GeocodingServiceException(
          'Invalid response format',
          code: 'INVALID_RESPONSE',
          originalError: e,
        );
      } catch (e) {
        if (e is GeocodingServiceException) rethrow;
        throw GeocodingServiceException(
          'Error reverse geocoding',
          code: 'REVERSE_GEOCODING_ERROR',
          originalError: e,
        );
      }
    });
  }

  Future<Map<String, String>?> getAddressComponents({
    required double lat,
    required double lng,
  }) async {
    _ensureNotDisposed();
    _validateCoordinates(lat, lng);

    return _retryOperation(() async {
      try {
        await _enforceRateLimit();

        final url = _buildReverseUrl(lat, lng);

        _logInfo('Getting address components: ($lat, $lng)');
        final response = await http
            .get(url, headers: _buildHeaders())
            .timeout(requestTimeout);

        _validateResponse(response, 'Address components');

        final data = json.decode(response.body) as Map<String, dynamic>;

        final addressData = data['address'];
        if (addressData == null) {
          _logWarning('No address components found: ($lat, $lng)');
          return null;
        }

        final components = _parseAddressComponents(addressData);
        _logInfo('Retrieved ${components.length} address components');

        return components;
      } on TimeoutException {
        throw GeocodingServiceException(
          'Address components request timed out',
          code: 'TIMEOUT',
        );
      } on FormatException catch (e) {
        throw GeocodingServiceException(
          'Invalid response format',
          code: 'INVALID_RESPONSE',
          originalError: e,
        );
      } catch (e) {
        if (e is GeocodingServiceException) rethrow;
        throw GeocodingServiceException(
          'Error getting address components',
          code: 'ADDRESS_COMPONENTS_ERROR',
          originalError: e,
        );
      }
    });
  }

  Uri _buildSearchUrl(String encodedAddress) {
    final params = {
      'format': 'json',
      'q': encodedAddress,
      'limit': '1',
      if (nominatimApiKey != null) 'key': nominatimApiKey!,
    };

    return Uri.parse('$nominatimBaseUrl/search').replace(
      queryParameters: params,
    );
  }

  Uri _buildReverseUrl(double lat, double lng) {
    final params = {
      'format': 'json',
      'lat': lat.toString(),
      'lon': lng.toString(),
      if (nominatimApiKey != null) 'key': nominatimApiKey!,
    };

    return Uri.parse('$nominatimBaseUrl/reverse').replace(
      queryParameters: params,
    );
  }

  Map<String, String> _buildHeaders() {
    return {
      'User-Agent': userAgent,
      'Accept': 'application/json',
    };
  }

  void _validateResponse(http.Response response, String operation) {
    if (response.statusCode == 429) {
      throw GeocodingServiceException(
        'Rate limit exceeded. Please wait before making more requests.',
        code: 'RATE_LIMIT_EXCEEDED',
      );
    }

    if (response.statusCode == 403) {
      throw GeocodingServiceException(
        'Access forbidden. Check API key or usage limits.',
        code: 'FORBIDDEN',
      );
    }

    if (response.statusCode != 200) {
      throw GeocodingServiceException(
        '$operation API returned status ${response.statusCode}',
        code: 'API_ERROR',
      );
    }

    if (response.body.isEmpty) {
      throw GeocodingServiceException(
        'Empty response from API',
        code: 'EMPTY_RESPONSE',
      );
    }
  }

  ({double lat, double lng}) _parseCoordinatesFromSearchResult(
    Map<String, dynamic> location,
  ) {
    try {
      final lat = double.parse(location['lat'].toString());
      final lng = double.parse(location['lon'].toString());
      _validateCoordinates(lat, lng);
      return (lat: lat, lng: lng);
    } catch (e) {
      throw GeocodingServiceException(
        'Invalid coordinates in response',
        code: 'INVALID_COORDINATES',
        originalError: e,
      );
    }
  }

  Map<String, String> _parseAddressComponents(dynamic addressData) {
    if (addressData is! Map) {
      throw GeocodingServiceException(
        'Invalid address data format',
        code: 'INVALID_ADDRESS_DATA',
      );
    }

    final components = <String, String>{};
    for (final entry in addressData.entries) {
      if (entry.value != null) {
        components[entry.key.toString()] = entry.value.toString();
      }
    }

    return components;
  }

  String _normalizeAddress(String address) {
    return address.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  void _validateCoordinates(double lat, double lng) {
    if (lat < -90 || lat > 90) {
      throw GeocodingServiceException(
        'Invalid latitude: $lat (must be between -90 and 90)',
        code: 'INVALID_LATITUDE',
      );
    }
    if (lng < -180 || lng > 180) {
      throw GeocodingServiceException(
        'Invalid longitude: $lng (must be between -180 and 180)',
        code: 'INVALID_LONGITUDE',
      );
    }
  }

  Future<void> _enforceRateLimit() async {
    if (_lastRequestTime != null) {
      final timeSinceLastRequest =
          DateTime.now().difference(_lastRequestTime!);
      if (timeSinceLastRequest < minRequestInterval) {
        final delay = minRequestInterval - timeSinceLastRequest;
        _logInfo('Rate limiting: waiting ${delay.inMilliseconds}ms');
        await Future.delayed(delay);
      }
    }
    _lastRequestTime = DateTime.now();
  }

  // FIX (QA P1): _retryOperation previously retried on ALL exceptions except
  // RATE_LIMIT_EXCEEDED. This caused:
  //   - INVALID_ADDRESS errors to be retried 3× with 2/4/6-second delays
  //     (12+ seconds of wasted time for a deterministic failure)
  //   - FORBIDDEN (403) to be retried (will never succeed without a new API key)
  //   - INVALID_COORDINATES to be retried (bad input never becomes valid)
  //
  // Fix: introduce _nonRetryableCodes. Any GeocodingServiceException whose
  // code is in this set is rethrown immediately on the first failure.
  // Network-level errors (timeouts, DNS failures, server 5xx) still retry
  // up to maxRetries times since those can be transient.
  Future<T> _retryOperation<T>(Future<T> Function() operation) async {
    int attempts = 0;

    while (attempts < maxRetries) {
      try {
        return await operation();
      } catch (e) {
        // Non-retryable: rethrow immediately, do not count as attempt.
        if (e is GeocodingServiceException &&
            _isNonRetryable(e)) {
          rethrow;
        }

        attempts++;

        if (attempts >= maxRetries) {
          rethrow;
        }

        final delay = baseRetryDelay * attempts;
        _logWarning('Retry $attempts/$maxRetries after ${delay.inSeconds}s');
        await Future.delayed(delay);
      }
    }

    throw GeocodingServiceException(
      'Max retries exceeded',
      code: 'MAX_RETRIES_EXCEEDED',
    );
  }

  /// Returns true for errors that will never succeed on a retry.
  bool _isNonRetryable(GeocodingServiceException e) {
    return e.code != null && _nonRetryableCodes.contains(e.code);
  }

  ({double lat, double lng})? _getFromGeocodingCache(String address) {
    final cached = _geocodingCache[address];
    if (cached == null) return null;

    if (cached.isExpired) {
      _geocodingCache.remove(address);
      return null;
    }

    return cached.coordinates;
  }

  void _cacheGeocodingResult(
    String address,
    ({double lat, double lng}) coordinates,
  ) {
    if (_geocodingCache.length >= maxCacheSize) {
      _evictOldestFromGeocodingCache();
    }
    _geocodingCache[address] =
        _CachedGeocodingResult(coordinates: coordinates);
  }

  String? _getFromReverseGeocodingCache(String cacheKey) {
    final cached = _reverseGeocodingCache[cacheKey];
    if (cached == null) return null;

    if (cached.isExpired) {
      _reverseGeocodingCache.remove(cacheKey);
      return null;
    }

    return cached.address;
  }

  void _cacheReverseGeocodingResult(String cacheKey, String address) {
    if (_reverseGeocodingCache.length >= maxCacheSize) {
      _evictOldestFromReverseGeocodingCache();
    }
    _reverseGeocodingCache[cacheKey] =
        _CachedGeocodingResult(address: address);
  }

  String _buildReverseGeocodingCacheKey(double lat, double lng) {
    final roundedLat = (lat * 1000).round() / 1000;
    final roundedLng = (lng * 1000).round() / 1000;
    return '$roundedLat,$roundedLng';
  }

  void _evictOldestFromGeocodingCache() {
    if (_geocodingCache.isEmpty) return;

    String? oldestKey;
    DateTime? oldestTime;

    for (final entry in _geocodingCache.entries) {
      if (oldestTime == null ||
          entry.value.cachedAt.isBefore(oldestTime)) {
        oldestKey = entry.key;
        oldestTime = entry.value.cachedAt;
      }
    }

    if (oldestKey != null) {
      _geocodingCache.remove(oldestKey);
    }
  }

  void _evictOldestFromReverseGeocodingCache() {
    if (_reverseGeocodingCache.isEmpty) return;

    String? oldestKey;
    DateTime? oldestTime;

    for (final entry in _reverseGeocodingCache.entries) {
      if (oldestTime == null ||
          entry.value.cachedAt.isBefore(oldestTime)) {
        oldestKey = entry.key;
        oldestTime = entry.value.cachedAt;
      }
    }

    if (oldestKey != null) {
      _reverseGeocodingCache.remove(oldestKey);
    }
  }

  void clearCache() {
    _geocodingCache.clear();
    _reverseGeocodingCache.clear();
    _logInfo('Cache cleared');
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw GeocodingServiceException(
        'GeocodingService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[GeocodingService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[GeocodingService] WARNING: $message');
  }

  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    _geocodingCache.clear();
    _reverseGeocodingCache.clear();
    _lastRequestTime = null;
    _logInfo('GeocodingService disposed');
  }
}

class _CachedGeocodingResult {
  final ({double lat, double lng})? coordinates;
  final String? address;
  final DateTime cachedAt;

  _CachedGeocodingResult({
    this.coordinates,
    this.address,
  }) : cachedAt = DateTime.now();

  bool get isExpired {
    final now = DateTime.now();
    return now.difference(cachedAt) > GeocodingService.cacheExpiration;
  }
}
