// lib/services/geohash_helper.dart
//
// FIX (A7 — duplicate class name): renamed GeoHashHelper → GeoHashHelperExtended.
//
// geo_cell_utils.dart defines a class also called GeoHashHelper (the canonical
// pure-Dart geohash implementation used by geographic_grid_service.dart).
// Having two classes with the same name in the same package caused:
//   • Dart analyzer "Duplicate definition" errors in files that import both.
//   • Silent shadowing bugs when one import masked the other, producing wrong
//     geohash strings depending on import order.
//
// GeoHashHelperExtended is the richer service-layer variant (neighbour lookup,
// radius expansion, cell-ID generation, full decode/bounds). It wraps the same
// base32 algorithm but adds higher-level utilities not present in geo_cell_utils.
//
// MIGRATION: replace GeoHashHelper with GeoHashHelperExtended at all call sites
// in lib/services/. geo_cell_utils.GeoHashHelper remains the canonical encoder
// used by geographic_grid_service.dart and the grid layer.
//
// ALGO FIX (encode — boundary tie-breaking):
//   encode() used `lng > mid` (strict greater-than) for the longitude bit
//   while geo_cell_utils.GeoHashHelper uses `lng >= mid` (greater-or-equal).
//   When a point falls exactly on a cell boundary (lng == mid), the two
//   implementations produced different hash strings for the same coordinate,
//   causing cell-ID mismatches between the grid layer and the service layer.
//
//   Fix: changed `lng > mid` → `lng >= mid` to match GeoHashHelper exactly.
//   The latitude branch already used `lat > mid` (consistent with RFC
//   geohash convention for latitude), which is left unchanged.

import 'package:flutter/foundation.dart';

class GeoHashException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  GeoHashException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'GeoHashException: $message${code != null ? ' (Code: $code)' : ''}';
}

/// Extended geohash utilities for the service layer.
///
/// Provides neighbour traversal, radius expansion, cell-ID generation, and
/// bounds computation on top of the standard base32 geohash algorithm.
///
/// For raw encoding/decoding, prefer [GeoHashHelper] from geo_cell_utils.dart
/// (no external dependencies, fully unit-testable).
class GeoHashHelperExtended {
  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';
  static const int _base32Length = 32;
  static const int _bitsPerChar = 5;
  static const int _minPrecision = 1;
  static const int _maxPrecision = 12;
  static const int _defaultPrecision = 6;
  static const int _wilayaCodeMaxDigits = 2;
  
  static const double _minLatitude = -90.0;
  static const double _maxLatitude = 90.0;
  static const double _minLongitude = -180.0;
  static const double _maxLongitude = 180.0;
  
  static const double _radiusMultiplierForNeighbors = 1.0;
  static const double _radiusMultiplierForExtendedSearch = 2.0;

  static const Map<String, String> _neighborMap = {
    'right_even': 'bc01fg45238967deuvhjyznpkmstqrwx',
    'left_even': '238967debc01fg45kmstqrwxuvhjyznp',
    'top_even': 'p0r21436x8zb9dcf5h7kjnmqesgutwvy',
    'bottom_even': '14365h7k9dcfesgujnmqp0r2twvyx8zb',
    'right_odd': 'p0r21436x8zb9dcf5h7kjnmqesgutwvy',
    'left_odd': '14365h7k9dcfesgujnmqp0r2twvyx8zb',
    'top_odd': 'bc01fg45238967deuvhjyznpkmstqrwx',
    'bottom_odd': '238967debc01fg45kmstqrwxuvhjyznp',
  };

  static const Map<String, String> _borderMap = {
    'right_even': 'bcfguvyz',
    'left_even': '0145hjnp',
    'top_even': 'prxz',
    'bottom_even': '028b',
    'right_odd': 'prxz',
    'left_odd': '028b',
    'top_odd': 'bcfguvyz',
    'bottom_odd': '0145hjnp',
  };

  static const Map<int, double> _precisionToSizeKm = {
    1: 5000.0,
    2: 1250.0,
    3: 156.0,
    4: 39.0,
    5: 4.9,
    6: 1.2,
    7: 0.15,
    8: 0.038,
    9: 0.0095,
    10: 0.0024,
    11: 0.0006,
    12: 0.00015,
  };

  /// Encodes [lat]/[lng] to a geohash of [precision] characters.
  ///
  /// ALGO FIX: changed `lng > mid` → `lng >= mid` for the longitude bit
  /// decision. The previous strict greater-than caused a boundary mismatch
  /// with GeoHashHelper (geo_cell_utils.dart) when lng fell exactly on a
  /// cell midpoint — the two helpers produced different hash strings for
  /// identical coordinates, breaking cell-ID lookups in the grid layer.
  static String encode(double lat, double lng, {int precision = _defaultPrecision}) {
    _validatePrecision(precision);
    _validateCoordinates(lat, lng);

    try {
      List<double> latRange = [_minLatitude, _maxLatitude];
      List<double> lngRange = [_minLongitude, _maxLongitude];
      String hash = '';
      int bits = 0;
      int bit = 0;
      bool isEven = true;

      while (hash.length < precision) {
        if (isEven) {
          final mid = (lngRange[0] + lngRange[1]) / 2;
          // FIX: >= to match GeoHashHelper boundary convention.
          if (lng >= mid) {
            bit |= (1 << (_bitsPerChar - 1 - bits));
            lngRange[0] = mid;
          } else {
            lngRange[1] = mid;
          }
        } else {
          final mid = (latRange[0] + latRange[1]) / 2;
          if (lat > mid) {
            bit |= (1 << (_bitsPerChar - 1 - bits));
            latRange[0] = mid;
          } else {
            latRange[1] = mid;
          }
        }

        isEven = !isEven;
        bits++;

        if (bits == _bitsPerChar) {
          hash += _base32[bit];
          bits = 0;
          bit = 0;
        }
      }

      _logInfo('Encoded ($lat, $lng) to: $hash');
      return hash;
    } catch (e) {
      throw GeoHashException(
        'Failed to encode coordinates',
        code: 'ENCODE_FAILED',
        originalError: e,
      );
    }
  }

  static Map<String, double> decode(String geoHash) {
    _validateGeoHash(geoHash);

    try {
      List<double> latRange = [_minLatitude, _maxLatitude];
      List<double> lngRange = [_minLongitude, _maxLongitude];
      bool isEven = true;

      for (int i = 0; i < geoHash.length; i++) {
        final char = geoHash[i].toLowerCase();
        final idx = _base32.indexOf(char);

        if (idx == -1) {
          throw GeoHashException(
            'Invalid GeoHash character: $char at position $i',
            code: 'INVALID_CHARACTER',
          );
        }

        for (int bit = _bitsPerChar - 1; bit >= 0; bit--) {
          final bitValue = (idx >> bit) & 1;

          if (isEven) {
            final mid = (lngRange[0] + lngRange[1]) / 2;
            if (bitValue == 1) {
              lngRange[0] = mid;
            } else {
              lngRange[1] = mid;
            }
          } else {
            final mid = (latRange[0] + latRange[1]) / 2;
            if (bitValue == 1) {
              latRange[0] = mid;
            } else {
              latRange[1] = mid;
            }
          }

          isEven = !isEven;
        }
      }

      final lat = (latRange[0] + latRange[1]) / 2;
      final lng = (lngRange[0] + lngRange[1]) / 2;
      final latError = (latRange[1] - latRange[0]) / 2;
      final lngError = (lngRange[1] - lngRange[0]) / 2;

      return {
        'latitude': lat,
        'longitude': lng,
        'latError': latError,
        'lngError': lngError,
      };
    } catch (e) {
      if (e is GeoHashException) rethrow;
      throw GeoHashException(
        'Failed to decode GeoHash',
        code: 'DECODE_FAILED',
        originalError: e,
      );
    }
  }

  static String generateCellId(int wilayaCode, double lat, double lng) {
    _validateWilayaCode(wilayaCode);
    _validateCoordinates(lat, lng);

    try {
      final geoHash = encode(lat, lng, precision: _defaultPrecision);
      return '${wilayaCode.toString().padLeft(_wilayaCodeMaxDigits, '0')}_$geoHash';
    } catch (e) {
      throw GeoHashException(
        'Failed to generate cell ID',
        code: 'CELL_ID_GENERATION_FAILED',
        originalError: e,
      );
    }
  }

  static String getNeighbor(String geoHash, String direction) {
    _validateGeoHash(geoHash);
    _validateDirection(direction);

    if (geoHash.isEmpty) {
      throw GeoHashException(
        'GeoHash cannot be empty',
        code: 'EMPTY_GEOHASH',
      );
    }

    try {
      final lastChar = geoHash[geoHash.length - 1].toLowerCase();
      final parent = geoHash.substring(0, geoHash.length - 1);
      final type = geoHash.length % 2 == 0 ? 'even' : 'odd';

      final borderKey = '${direction}_$type';
      final border = _borderMap[borderKey];

      if (border == null) {
        throw GeoHashException(
          'Invalid border key: $borderKey',
          code: 'INVALID_BORDER_KEY',
        );
      }

      if (border.contains(lastChar) && parent.isNotEmpty) {
        final newParent = getNeighbor(parent, direction);
        final neighborKey = '${direction}_$type';
        final neighborChars = _neighborMap[neighborKey];

        if (neighborChars == null) {
          throw GeoHashException(
            'Invalid neighbor key: $neighborKey',
            code: 'INVALID_NEIGHBOR_KEY',
          );
        }

        final idx = _base32.indexOf(lastChar);
        return newParent + neighborChars[idx];
      }

      final neighborKey = '${direction}_$type';
      final neighborChars = _neighborMap[neighborKey];

      if (neighborChars == null) {
        throw GeoHashException(
          'Invalid neighbor key: $neighborKey',
          code: 'INVALID_NEIGHBOR_KEY',
        );
      }

      final idx = _base32.indexOf(lastChar);
      final newChar = neighborChars[idx];

      return parent + newChar;
    } catch (e) {
      if (e is GeoHashException) rethrow;
      throw GeoHashException(
        'Failed to get neighbor',
        code: 'GET_NEIGHBOR_FAILED',
        originalError: e,
      );
    }
  }

  static List<String> getAdjacentCells(String cellId) {
    if (cellId.trim().isEmpty) {
      _logWarning('getAdjacentCells called with empty cellId');
      return [];
    }

    final parts = cellId.split('_');
    if (parts.length != 2) {
      _logWarning('Invalid cell ID format: $cellId');
      return [];
    }

    try {
      final wilaya = parts[0];
      final geoHash = parts[1];

      return _getGeoHashNeighbors(geoHash)
          .map((neighbor) => '${wilaya}_$neighbor')
          .toList();
    } catch (e) {
      _logError('getAdjacentCells', e);
      return [];
    }
  }

  static List<String> _getGeoHashNeighbors(String geoHash) {
    final neighbors = <String>[];

    try {
      final top = getNeighbor(geoHash, 'top');
      neighbors.add(top);

      final topRight = getNeighbor(top, 'right');
      neighbors.add(topRight);

      final right = getNeighbor(geoHash, 'right');
      neighbors.add(right);

      final bottomRight = getNeighbor(right, 'bottom');
      neighbors.add(bottomRight);

      final bottom = getNeighbor(geoHash, 'bottom');
      neighbors.add(bottom);

      final bottomLeft = getNeighbor(bottom, 'left');
      neighbors.add(bottomLeft);

      final left = getNeighbor(geoHash, 'left');
      neighbors.add(left);

      final topLeft = getNeighbor(left, 'top');
      neighbors.add(topLeft);

      return neighbors;
    } catch (e) {
      _logError('_getGeoHashNeighbors', e);
      return [];
    }
  }

  static Map<String, double> getBounds(String geoHash) {
    _validateGeoHash(geoHash);

    try {
      List<double> latRange = [_minLatitude, _maxLatitude];
      List<double> lngRange = [_minLongitude, _maxLongitude];
      bool isEven = true;

      for (int i = 0; i < geoHash.length; i++) {
        final char = geoHash[i].toLowerCase();
        final idx = _base32.indexOf(char);

        if (idx == -1) {
          throw GeoHashException(
            'Invalid GeoHash character: $char at position $i',
            code: 'INVALID_CHARACTER',
          );
        }

        for (int bit = _bitsPerChar - 1; bit >= 0; bit--) {
          final bitValue = (idx >> bit) & 1;

          if (isEven) {
            final mid = (lngRange[0] + lngRange[1]) / 2;
            if (bitValue == 1) {
              lngRange[0] = mid;
            } else {
              lngRange[1] = mid;
            }
          } else {
            final mid = (latRange[0] + latRange[1]) / 2;
            if (bitValue == 1) {
              latRange[0] = mid;
            } else {
              latRange[1] = mid;
            }
          }

          isEven = !isEven;
        }
      }

      return {
        'minLat': latRange[0],
        'maxLat': latRange[1],
        'minLng': lngRange[0],
        'maxLng': lngRange[1],
      };
    } catch (e) {
      if (e is GeoHashException) rethrow;
      throw GeoHashException(
        'Failed to get bounds',
        code: 'GET_BOUNDS_FAILED',
        originalError: e,
      );
    }
  }

  static List<String> getGeoHashesInRadius(
    double lat,
    double lng,
    double radiusKm, {
    int precision = _defaultPrecision,
  }) {
    _validateCoordinates(lat, lng);
    _validatePrecision(precision);

    if (radiusKm <= 0) {
      throw GeoHashException(
        'Radius must be positive: $radiusKm',
        code: 'INVALID_RADIUS',
      );
    }

    try {
      final center = encode(lat, lng, precision: precision);
      final geohashes = <String>{center};

      final cellSizeKm = _estimateCellSize(precision);

      if (radiusKm > cellSizeKm * _radiusMultiplierForNeighbors) {
        geohashes.addAll(_getGeoHashNeighbors(center));

        if (radiusKm > cellSizeKm * _radiusMultiplierForExtendedSearch) {
          final neighbors = _getGeoHashNeighbors(center);
          for (final neighbor in neighbors) {
            geohashes.addAll(_getGeoHashNeighbors(neighbor));
          }
        }
      }

      _logInfo('Found ${geohashes.length} geohashes within ${radiusKm}km radius');
      return geohashes.toList();
    } catch (e) {
      if (e is GeoHashException) rethrow;
      throw GeoHashException(
        'Failed to get geohashes in radius',
        code: 'GET_RADIUS_FAILED',
        originalError: e,
      );
    }
  }

  static double _estimateCellSize(int precision) {
    final size = _precisionToSizeKm[precision];
    if (size == null) {
      _logWarning('Unknown precision: $precision, using default');
      return _precisionToSizeKm[_defaultPrecision]!;
    }
    return size;
  }

  static void _validatePrecision(int precision) {
    if (precision < _minPrecision || precision > _maxPrecision) {
      throw GeoHashException(
        'Precision must be between $_minPrecision and $_maxPrecision, got: $precision',
        code: 'INVALID_PRECISION',
      );
    }
  }

  static void _validateCoordinates(double lat, double lng) {
    if (lat < _minLatitude || lat > _maxLatitude) {
      throw GeoHashException(
        'Invalid latitude: $lat (must be between $_minLatitude and $_maxLatitude)',
        code: 'INVALID_LATITUDE',
      );
    }

    if (lng < _minLongitude || lng > _maxLongitude) {
      throw GeoHashException(
        'Invalid longitude: $lng (must be between $_minLongitude and $_maxLongitude)',
        code: 'INVALID_LONGITUDE',
      );
    }
  }

  static void _validateGeoHash(String geoHash) {
    if (geoHash.trim().isEmpty) {
      throw GeoHashException(
        'GeoHash cannot be empty',
        code: 'EMPTY_GEOHASH',
      );
    }

    if (geoHash.length > _maxPrecision) {
      throw GeoHashException(
        'GeoHash too long: ${geoHash.length} (max: $_maxPrecision)',
        code: 'GEOHASH_TOO_LONG',
      );
    }

    for (int i = 0; i < geoHash.length; i++) {
      final char = geoHash[i].toLowerCase();
      if (!_base32.contains(char)) {
        throw GeoHashException(
          'Invalid GeoHash character: $char at position $i',
          code: 'INVALID_CHARACTER',
        );
      }
    }
  }

  static void _validateDirection(String direction) {
    const validDirections = ['top', 'bottom', 'left', 'right'];
    if (!validDirections.contains(direction.toLowerCase())) {
      throw GeoHashException(
        'Invalid direction: $direction (must be one of: ${validDirections.join(", ")})',
        code: 'INVALID_DIRECTION',
      );
    }
  }

  static void _validateWilayaCode(int wilayaCode) {
    if (wilayaCode < 1 || wilayaCode > 58) {
      throw GeoHashException(
        'Invalid wilaya code: $wilayaCode (must be between 1 and 58)',
        code: 'INVALID_WILAYA_CODE',
      );
    }
  }

  static void _logInfo(String message) {
    if (kDebugMode) debugPrint('[GeoHashHelperExtended] INFO: $message');
  }

  static void _logWarning(String message) {
    if (kDebugMode) debugPrint('[GeoHashHelperExtended] WARNING: $message');
  }

  static void _logError(String method, dynamic error) {
    if (kDebugMode) debugPrint('[GeoHashHelperExtended] ERROR in $method: $error');
  }
}
