// lib/services/wilaya_manager.dart

import 'package:flutter/foundation.dart';
import '../models/wilaya_model.dart';
import 'wilaya_manager_interface.dart';

class WilayaManagerException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  WilayaManagerException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'WilayaManagerException: $message${code != null ? ' (Code: $code)' : ''}';
}

class WilayaManager implements WilayaManagerInterface {
  static const int minWilayaCode = 1;
  static const int maxWilayaCode = 58;
  static const int totalWilayasCount = 58;
  static const int minSearchQueryLength = 1;
  static const int maxSearchQueryLength = 100;

  late final Map<int, WilayaModel> _wilayas;
  final Map<String, List<WilayaModel>> _searchCache = {};
  bool _isDisposed = false;

  WilayaManager() {
    _wilayas = _initializeWilayas();
    _validateWilayasData();
    _logInfo('WilayaManager initialized with ${_wilayas.length} wilayas');
  }

  Map<int, WilayaModel> get wilayas => Map.unmodifiable(_wilayas);
  bool get isDisposed => _isDisposed;
  int get wilayasCount => _wilayas.length;

  WilayaModel? getWilaya(int code) {
    _ensureNotDisposed();
    
    if (!_isValidWilayaCode(code)) {
      _logWarning('Invalid wilaya code requested: $code');
      return null;
    }

    return _wilayas[code];
  }

  WilayaModel getWilayaOrThrow(int code) {
    _ensureNotDisposed();
    _validateWilayaCode(code);

    final wilaya = _wilayas[code];
    
    if (wilaya == null) {
      throw WilayaManagerException(
        'Wilaya not found: $code',
        code: 'WILAYA_NOT_FOUND',
      );
    }

    return wilaya;
  }

  String? getWilayaName(int code) {
    _ensureNotDisposed();
    return _wilayas[code]?.name;
  }

  String getWilayaNameOrDefault(int code, [String defaultValue = 'Unknown']) {
    _ensureNotDisposed();
    return _wilayas[code]?.name ?? defaultValue;
  }

  String? getWilayaArabicName(int code) {
    _ensureNotDisposed();
    return _wilayas[code]?.arabicName;
  }

  String getWilayaArabicNameOrDefault(int code, [String defaultValue = 'غير معروف']) {
    _ensureNotDisposed();
    return _wilayas[code]?.arabicName ?? defaultValue;
  }

  List<WilayaModel> getNeighboringWilayas(int code) {
    _ensureNotDisposed();
    
    final wilaya = _wilayas[code];
    if (wilaya == null) {
      _logWarning('Cannot get neighbors for invalid wilaya: $code');
      return [];
    }

    return wilaya.neighboringWilayas
        .map((neighborCode) => _wilayas[neighborCode])
        .whereType<WilayaModel>()
        .toList();
  }

  bool areNeighbors(int wilayaCode1, int wilayaCode2) {
    _ensureNotDisposed();
    
    if (!_isValidWilayaCode(wilayaCode1) || !_isValidWilayaCode(wilayaCode2)) {
      return false;
    }

    if (wilayaCode1 == wilayaCode2) {
      return false;
    }

    final wilaya = _wilayas[wilayaCode1];
    if (wilaya == null) return false;
    
    return wilaya.neighboringWilayas.contains(wilayaCode2);
  }

  ({double lat, double lng})? getWilayaCenter(int code) {
    _ensureNotDisposed();
    
    final wilaya = _wilayas[code];
    if (wilaya == null) return null;
    
    return (lat: wilaya.centerLat, lng: wilaya.centerLng);
  }

  List<WilayaModel> searchWilayas(String query) {
    _ensureNotDisposed();
    _validateSearchQuery(query);

    final normalizedQuery = query.trim();
    
    if (normalizedQuery.isEmpty) {
      return getAllWilayas();
    }

    final cacheKey = normalizedQuery.toLowerCase();
    if (_searchCache.containsKey(cacheKey)) {
      _logInfo('Search cache hit: $normalizedQuery');
      return _searchCache[cacheKey]!;
    }

    final lowerQuery = normalizedQuery.toLowerCase();
    final results = _wilayas.values.where((wilaya) {
      return wilaya.name.toLowerCase().contains(lowerQuery) ||
          wilaya.arabicName.contains(normalizedQuery) ||
          wilaya.code.toString() == normalizedQuery;
    }).toList();

    results.sort((a, b) {
      final aStartsWithFrench = a.name.toLowerCase().startsWith(lowerQuery);
      final bStartsWithFrench = b.name.toLowerCase().startsWith(lowerQuery);
      
      if (aStartsWithFrench && !bStartsWithFrench) return -1;
      if (!aStartsWithFrench && bStartsWithFrench) return 1;
      
      return a.name.compareTo(b.name);
    });

    _searchCache[cacheKey] = results;
    _logInfo('Search completed for "$normalizedQuery": ${results.length} results');

    return results;
  }

  List<WilayaModel> getAllWilayas() {
    _ensureNotDisposed();
    return _wilayas.values.toList()..sort((a, b) => a.code.compareTo(b.code));
  }

  List<WilayaModel> getWilayasByRegion(String region) {
    _ensureNotDisposed();
    
    if (region.trim().isEmpty) {
      throw WilayaManagerException(
        'Region cannot be empty',
        code: 'INVALID_REGION',
      );
    }

    final normalizedRegion = region.toLowerCase().trim();
    
    return _wilayas.values
        .where((wilaya) => _getRegionForWilaya(wilaya).toLowerCase() == normalizedRegion)
        .toList();
  }

  List<WilayaModel> getCoastalWilayas() {
    _ensureNotDisposed();
    
    const coastalCodes = [
      2, 6, 9, 13, 15, 16, 18, 21, 23, 27, 31, 35, 36, 42, 46
    ];
    
    return coastalCodes
        .map((code) => _wilayas[code])
        .whereType<WilayaModel>()
        .toList();
  }

  List<WilayaModel> getSaharanWilayas() {
    _ensureNotDisposed();
    
    const saharanCodes = [
      1, 8, 11, 30, 32, 33, 37, 39, 47, 49, 50, 52, 53, 54, 55, 56, 57, 58
    ];
    
    return saharanCodes
        .map((code) => _wilayas[code])
        .whereType<WilayaModel>()
        .toList();
  }

  bool isCoastalWilaya(int code) {
    _ensureNotDisposed();
    const coastalCodes = [2, 6, 9, 13, 15, 16, 18, 21, 23, 27, 31, 35, 36, 42, 46];
    return coastalCodes.contains(code);
  }

  bool isSaharanWilaya(int code) {
    _ensureNotDisposed();
    const saharanCodes = [1, 8, 11, 30, 32, 33, 37, 39, 47, 49, 50, 52, 53, 54, 55, 56, 57, 58];
    return saharanCodes.contains(code);
  }

  int getNeighborCount(int code) {
    _ensureNotDisposed();
    final wilaya = _wilayas[code];
    return wilaya?.neighboringWilayas.length ?? 0;
  }

  WilayaModel? findWilayaByName(String name) {
    _ensureNotDisposed();
    
    if (name.trim().isEmpty) {
      return null;
    }

    final normalized = name.trim().toLowerCase();
    
    return _wilayas.values.firstWhere(
      (wilaya) => wilaya.name.toLowerCase() == normalized,
      orElse: () => _wilayas.values.firstWhere(
        (wilaya) => wilaya.arabicName == name.trim(),
        orElse: () => throw StateError('Not found'),
      ),
    );
  }

  bool wilayaExists(int code) {
    _ensureNotDisposed();
    return _wilayas.containsKey(code);
  }

  String _getRegionForWilaya(WilayaModel wilaya) {
    const northRegion = [2, 6, 9, 10, 13, 15, 16, 18, 21, 23, 27, 31, 35, 36, 42, 44, 46];
    const highPlateaus = [3, 4, 5, 7, 14, 17, 19, 20, 22, 26, 28, 29, 38, 40, 41, 43, 48, 51];
    const sahara = [1, 8, 11, 30, 32, 33, 37, 39, 47, 49, 50, 52, 53, 54, 55, 56, 57, 58];
    
    if (northRegion.contains(wilaya.code)) return 'north';
    if (highPlateaus.contains(wilaya.code)) return 'high_plateaus';
    if (sahara.contains(wilaya.code)) return 'sahara';
    
    return 'unknown';
  }

  bool _isValidWilayaCode(int code) {
    return code >= minWilayaCode && code <= maxWilayaCode;
  }

  void _validateWilayaCode(int code) {
    if (!_isValidWilayaCode(code)) {
      throw WilayaManagerException(
        'Invalid wilaya code: $code (must be between $minWilayaCode and $maxWilayaCode)',
        code: 'INVALID_WILAYA_CODE',
      );
    }
  }

  void _validateSearchQuery(String query) {
    if (query.length > maxSearchQueryLength) {
      throw WilayaManagerException(
        'Search query too long: ${query.length} characters (max: $maxSearchQueryLength)',
        code: 'QUERY_TOO_LONG',
      );
    }
  }

  void _validateWilayasData() {
    if (_wilayas.length != totalWilayasCount) {
      _logWarning(
        'Expected $totalWilayasCount wilayas, found ${_wilayas.length}',
      );
    }

    for (final wilaya in _wilayas.values) {
      for (final neighborCode in wilaya.neighboringWilayas) {
        if (!_wilayas.containsKey(neighborCode)) {
          _logWarning(
            'Wilaya ${wilaya.code} has invalid neighbor: $neighborCode',
          );
        }
      }
    }

    _logInfo('Wilayas data validation complete');
  }

  void clearSearchCache() {
    _searchCache.clear();
    _logInfo('Search cache cleared');
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw WilayaManagerException(
        'WilayaManager has been disposed',
        code: 'MANAGER_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[WilayaManager] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[WilayaManager] WARNING: $message');
  }

  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    _searchCache.clear();
    _logInfo('WilayaManager disposed');
  }

  Map<int, WilayaModel> _initializeWilayas() {
    return {
      1: const WilayaModel(
        code: 1,
        name: 'Adrar',
        arabicName: 'أدرار',
        centerLat: 27.8667,
        centerLng: -0.2833,
        neighboringWilayas: [8, 11, 30, 47, 37],
      ),
      2: const WilayaModel(
        code: 2,
        name: 'Chlef',
        arabicName: 'الشلف',
        centerLat: 36.1667,
        centerLng: 1.3333,
        neighboringWilayas: [9, 44, 38, 42],
      ),
      3: const WilayaModel(
        code: 3,
        name: 'Laghouat',
        arabicName: 'الأغواط',
        centerLat: 33.8000,
        centerLng: 2.8667,
        neighboringWilayas: [17, 28, 7, 47, 32, 14],
      ),
      4: const WilayaModel(
        code: 4,
        name: 'Oum El Bouaghi',
        arabicName: 'أم البواقي',
        centerLat: 35.8667,
        centerLng: 7.1167,
        neighboringWilayas: [5, 28, 19, 43, 41, 24],
      ),
      5: const WilayaModel(
        code: 5,
        name: 'Batna',
        arabicName: 'باتنة',
        centerLat: 35.5667,
        centerLng: 6.1667,
        neighboringWilayas: [4, 40, 7, 28],
      ),
      6: const WilayaModel(
        code: 6,
        name: 'Béjaïa',
        arabicName: 'بجاية',
        centerLat: 36.7500,
        centerLng: 5.0833,
        neighboringWilayas: [15, 10, 19],
      ),
      7: const WilayaModel(
        code: 7,
        name: 'Biskra',
        arabicName: 'بسكرة',
        centerLat: 34.8500,
        centerLng: 5.7333,
        neighboringWilayas: [28, 5, 40, 39, 30, 47, 3],
      ),
      8: const WilayaModel(
        code: 8,
        name: 'Béchar',
        arabicName: 'بشار',
        centerLat: 31.6167,
        centerLng: -2.2167,
        neighboringWilayas: [1, 37, 32, 45],
      ),
      9: const WilayaModel(
        code: 9,
        name: 'Blida',
        arabicName: 'البليدة',
        centerLat: 36.4833,
        centerLng: 2.8333,
        neighboringWilayas: [16, 44, 26, 2, 42],
      ),
      10: const WilayaModel(
        code: 10,
        name: 'Bouira',
        arabicName: 'البويرة',
        centerLat: 36.3833,
        centerLng: 3.9000,
        neighboringWilayas: [15, 35, 44, 26, 28, 19, 6],
      ),
      11: const WilayaModel(
        code: 11,
        name: 'Tamanrasset',
        arabicName: 'تمنراست',
        centerLat: 22.7833,
        centerLng: 5.5167,
        neighboringWilayas: [1, 30, 33],
      ),
      12: const WilayaModel(
        code: 12,
        name: 'Tébessa',
        arabicName: 'تبسة',
        centerLat: 35.4000,
        centerLng: 8.1167,
        neighboringWilayas: [4, 24, 36, 40],
      ),
      13: const WilayaModel(
        code: 13,
        name: 'Tlemcen',
        arabicName: 'تلمسان',
        centerLat: 34.8833,
        centerLng: -1.3167,
        neighboringWilayas: [22, 45, 46],
      ),
      14: const WilayaModel(
        code: 14,
        name: 'Tiaret',
        arabicName: 'تيارت',
        centerLat: 35.3708,
        centerLng: 1.3228,
        neighboringWilayas: [3, 17, 48, 20, 38, 26, 44],
      ),
      15: const WilayaModel(
        code: 15,
        name: 'Tizi Ouzou',
        arabicName: 'تيزي وزو',
        centerLat: 36.7000,
        centerLng: 4.0500,
        neighboringWilayas: [16, 35, 6, 10],
      ),
      16: const WilayaModel(
        code: 16,
        name: 'Alger',
        arabicName: 'الجزائر',
        centerLat: 36.7539,
        centerLng: 3.0588,
        neighboringWilayas: [42, 9, 44, 15, 35],
      ),
      17: const WilayaModel(
        code: 17,
        name: 'Djelfa',
        arabicName: 'الجلفة',
        centerLat: 34.6667,
        centerLng: 3.2500,
        neighboringWilayas: [3, 28, 51, 47, 14, 26],
      ),
      18: const WilayaModel(
        code: 18,
        name: 'Jijel',
        arabicName: 'جيجل',
        centerLat: 36.8167,
        centerLng: 5.7667,
        neighboringWilayas: [21, 43, 19],
      ),
      19: const WilayaModel(
        code: 19,
        name: 'Sétif',
        arabicName: 'سطيف',
        centerLat: 36.1833,
        centerLng: 5.4000,
        neighboringWilayas: [6, 10, 28, 4, 43, 18],
      ),
      20: const WilayaModel(
        code: 20,
        name: 'Saïda',
        arabicName: 'سعيدة',
        centerLat: 34.8333,
        centerLng: 0.1500,
        neighboringWilayas: [14, 48, 29, 22],
      ),
      21: const WilayaModel(
        code: 21,
        name: 'Skikda',
        arabicName: 'سكيكدة',
        centerLat: 36.8667,
        centerLng: 6.9000,
        neighboringWilayas: [18, 43, 41, 23, 36],
      ),
      22: const WilayaModel(
        code: 22,
        name: 'Sidi Bel Abbès',
        arabicName: 'سيدي بلعباس',
        centerLat: 35.2000,
        centerLng: -0.6333,
        neighboringWilayas: [13, 45, 20, 29, 46],
      ),
      23: const WilayaModel(
        code: 23,
        name: 'Annaba',
        arabicName: 'عنابة',
        centerLat: 36.9000,
        centerLng: 7.7667,
        neighboringWilayas: [21, 36, 41],
      ),
      24: const WilayaModel(
        code: 24,
        name: 'Guelma',
        arabicName: 'قالمة',
        centerLat: 36.4667,
        centerLng: 7.4333,
        neighboringWilayas: [4, 41, 21, 36, 12],
      ),
      25: const WilayaModel(
        code: 25,
        name: 'Constantine',
        arabicName: 'قسنطينة',
        centerLat: 36.3650,
        centerLng: 6.6147,
        neighboringWilayas: [43, 41, 50],
      ),
      26: const WilayaModel(
        code: 26,
        name: 'Médéa',
        arabicName: 'المدية',
        centerLat: 36.2667,
        centerLng: 2.7500,
        neighboringWilayas: [9, 44, 2, 38, 14, 17, 10],
      ),
      27: const WilayaModel(
        code: 27,
        name: 'Mostaganem',
        arabicName: 'مستغانم',
        centerLat: 35.9333,
        centerLng: 0.0833,
        neighboringWilayas: [29, 48, 38, 42],
      ),
      28: const WilayaModel(
        code: 28,
        name: 'M\'Sila',
        arabicName: 'المسيلة',
        centerLat: 35.7000,
        centerLng: 4.5333,
        neighboringWilayas: [10, 26, 17, 3, 7, 5, 4, 19],
      ),
      29: const WilayaModel(
        code: 29,
        name: 'Mascara',
        arabicName: 'معسكر',
        centerLat: 35.3960,
        centerLng: 0.1400,
        neighboringWilayas: [27, 48, 20, 22, 46],
      ),
      30: const WilayaModel(
        code: 30,
        name: 'Ouargla',
        arabicName: 'ورقلة',
        centerLat: 31.9500,
        centerLng: 5.3333,
        neighboringWilayas: [7, 39, 33, 11, 47],
      ),
      31: const WilayaModel(
        code: 31,
        name: 'Oran',
        arabicName: 'وهران',
        centerLat: 35.6969,
        centerLng: -0.6331,
        neighboringWilayas: [46, 38, 42],
      ),
      32: const WilayaModel(
        code: 32,
        name: 'El Bayadh',
        arabicName: 'البيض',
        centerLat: 33.6833,
        centerLng: 1.0167,
        neighboringWilayas: [8, 45, 48, 14, 3, 47],
      ),
      33: const WilayaModel(
        code: 33,
        name: 'Illizi',
        arabicName: 'إليزي',
        centerLat: 26.5000,
        centerLng: 8.4667,
        neighboringWilayas: [30, 11],
      ),
      34: const WilayaModel(
        code: 34,
        name: 'Bordj Bou Arréridj',
        arabicName: 'برج بوعريريج',
        centerLat: 36.0667,
        centerLng: 4.7667,
        neighboringWilayas: [10, 28, 19, 43],
      ),
      35: const WilayaModel(
        code: 35,
        name: 'Boumerdès',
        arabicName: 'بومرداس',
        centerLat: 36.7667,
        centerLng: 3.4833,
        neighboringWilayas: [16, 15, 10, 44],
      ),
      36: const WilayaModel(
        code: 36,
        name: 'El Tarf',
        arabicName: 'الطارف',
        centerLat: 36.7667,
        centerLng: 8.3167,
        neighboringWilayas: [23, 21, 24, 12],
      ),
      37: const WilayaModel(
        code: 37,
        name: 'Tindouf',
        arabicName: 'تندوف',
        centerLat: 27.6750,
        centerLng: -8.1333,
        neighboringWilayas: [8, 1],
      ),
      38: const WilayaModel(
        code: 38,
        name: 'Tissemsilt',
        arabicName: 'تيسمسيلت',
        centerLat: 35.6000,
        centerLng: 1.8167,
        neighboringWilayas: [2, 26, 14, 48, 27, 42],
      ),
      39: const WilayaModel(
        code: 39,
        name: 'El Oued',
        arabicName: 'الوادي',
        centerLat: 33.3667,
        centerLng: 6.8667,
        neighboringWilayas: [7, 30, 40],
      ),
      40: const WilayaModel(
        code: 40,
        name: 'Khenchela',
        arabicName: 'خنشلة',
        centerLat: 35.4333,
        centerLng: 7.1500,
        neighboringWilayas: [5, 7, 39, 12],
      ),
      41: const WilayaModel(
        code: 41,
        name: 'Souk Ahras',
        arabicName: 'سوق أهراس',
        centerLat: 36.2833,
        centerLng: 7.9500,
        neighboringWilayas: [4, 24, 23, 21, 43, 25],
      ),
      42: const WilayaModel(
        code: 42,
        name: 'Tipaza',
        arabicName: 'تيبازة',
        centerLat: 36.5931,
        centerLng: 2.4458,
        neighboringWilayas: [16, 9, 2, 38, 27, 31],
      ),
      43: const WilayaModel(
        code: 43,
        name: 'Mila',
        arabicName: 'ميلة',
        centerLat: 36.4500,
        centerLng: 6.2667,
        neighboringWilayas: [18, 19, 34, 25, 50, 41, 21],
      ),
      44: const WilayaModel(
        code: 44,
        name: 'Aïn Defla',
        arabicName: 'عين الدفلى',
        centerLat: 36.2667,
        centerLng: 1.9667,
        neighboringWilayas: [2, 9, 16, 35, 10, 26, 14],
      ),
      45: const WilayaModel(
        code: 45,
        name: 'Naâma',
        arabicName: 'النعامة',
        centerLat: 33.2667,
        centerLng: -0.3167,
        neighboringWilayas: [8, 32, 48, 22, 13],
      ),
      46: const WilayaModel(
        code: 46,
        name: 'Aïn Témouchent',
        arabicName: 'عين تموشنت',
        centerLat: 35.2986,
        centerLng: -1.1392,
        neighboringWilayas: [13, 22, 29, 31, 2],
      ),
      47: const WilayaModel(
        code: 47,
        name: 'Ghardaïa',
        arabicName: 'غرداية',
        centerLat: 32.4833,
        centerLng: 3.6667,
        neighboringWilayas: [3, 17, 51, 30, 1],
      ),
      48: const WilayaModel(
        code: 48,
        name: 'Relizane',
        arabicName: 'غليزان',
        centerLat: 35.7372,
        centerLng: 0.5536,
        neighboringWilayas: [14, 20, 29, 27, 38, 32, 45],
      ),
      49: const WilayaModel(
        code: 49,
        name: 'Timimoun',
        arabicName: 'تيميمون',
        centerLat: 29.2500,
        centerLng: 0.2333,
        neighboringWilayas: [1, 47, 8],
      ),
      50: const WilayaModel(
        code: 50,
        name: 'Bordj Badji Mokhtar',
        arabicName: 'برج باجي مختار',
        centerLat: 21.3333,
        centerLng: 0.9500,
        neighboringWilayas: [11, 1],
      ),
      51: const WilayaModel(
        code: 51,
        name: 'Ouled Djellal',
        arabicName: 'أولاد جلال',
        centerLat: 34.4167,
        centerLng: 5.0333,
        neighboringWilayas: [7, 17, 47, 30],
      ),
      52: const WilayaModel(
        code: 52,
        name: 'Béni Abbès',
        arabicName: 'بني عباس',
        centerLat: 30.1333,
        centerLng: -2.1667,
        neighboringWilayas: [8, 49, 1],
      ),
      53: const WilayaModel(
        code: 53,
        name: 'In Salah',
        arabicName: 'عين صالح',
        centerLat: 27.2000,
        centerLng: 2.4667,
        neighboringWilayas: [1, 11, 47, 49],
      ),
      54: const WilayaModel(
        code: 54,
        name: 'In Guezzam',
        arabicName: 'عين قزام',
        centerLat: 19.5667,
        centerLng: 5.7667,
        neighboringWilayas: [11],
      ),
      55: const WilayaModel(
        code: 55,
        name: 'Touggourt',
        arabicName: 'تقرت',
        centerLat: 33.1167,
        centerLng: 6.0667,
        neighboringWilayas: [30, 39, 7, 51],
      ),
      56: const WilayaModel(
        code: 56,
        name: 'Djanet',
        arabicName: 'جانت',
        centerLat: 24.5500,
        centerLng: 9.4833,
        neighboringWilayas: [33, 11],
      ),
      57: const WilayaModel(
        code: 57,
        name: 'El M\'Ghair',
        arabicName: 'المغير',
        centerLat: 33.9500,
        centerLng: 5.9333,
        neighboringWilayas: [39, 55, 51, 7],
      ),
      58: const WilayaModel(
        code: 58,
        name: 'El Meniaa',
        arabicName: 'المنيعة',
        centerLat: 30.5833,
        centerLng: 2.8833,
        neighboringWilayas: [47, 3, 53, 49],
      ),
    };
  }
}