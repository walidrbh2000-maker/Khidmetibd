// lib/services/permission_service.dart

import 'dart:async';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';

class PermissionServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  PermissionServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'PermissionServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class PermissionService {
  static const Duration permissionRequestTimeout = Duration(seconds: 30);
  static const Duration permissionCheckTimeout = Duration(seconds: 10);
  static const Duration statusCacheTTL = Duration(seconds: 30);
  static const int maxRetries = 2;
  static const Duration baseRetryDelay = Duration(seconds: 1);

  final Map<Permission, _CachedPermissionStatus> _statusCache = {};
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  Future<bool> hasLocationPermission() async {
    _ensureNotDisposed();
    return _checkPermissionStatus(Permission.location);
  }

  Future<bool> requestLocationPermission() async {
    _ensureNotDisposed();
    return _requestPermission(
      Permission.location,
      'location',
    );
  }

  Future<bool> hasLocationAlwaysPermission() async {
    _ensureNotDisposed();
    return _checkPermissionStatus(Permission.locationAlways);
  }

  Future<bool> requestLocationAlwaysPermission() async {
    _ensureNotDisposed();

    final hasRegularLocation = await hasLocationPermission();
    if (!hasRegularLocation) {
      _logWarning('Regular location permission not granted. Requesting first...');
      final granted = await requestLocationPermission();
      if (!granted) {
        throw PermissionServiceException(
          'Regular location permission must be granted before requesting background location',
          code: 'LOCATION_NOT_GRANTED',
        );
      }
    }

    return _requestPermission(
      Permission.locationAlways,
      'background location',
    );
  }

  Future<bool> hasCameraPermission() async {
    _ensureNotDisposed();
    return _checkPermissionStatus(Permission.camera);
  }

  Future<bool> requestCameraPermission() async {
    _ensureNotDisposed();
    return _requestPermission(
      Permission.camera,
      'camera',
    );
  }

  Future<bool> hasMicrophonePermission() async {
    _ensureNotDisposed();
    return _checkPermissionStatus(Permission.microphone);
  }

  Future<bool> requestMicrophonePermission() async {
    _ensureNotDisposed();
    return _requestPermission(
      Permission.microphone,
      'microphone',
    );
  }

  Future<bool> hasNotificationPermission() async {
    _ensureNotDisposed();
    return _checkPermissionStatus(Permission.notification);
  }

  Future<bool> requestNotificationPermission() async {
    _ensureNotDisposed();
    return _requestPermission(
      Permission.notification,
      'notification',
    );
  }

  Future<bool> hasStoragePermission() async {
    _ensureNotDisposed();
    return _checkPermissionStatus(Permission.storage);
  }

  Future<bool> requestStoragePermission() async {
    _ensureNotDisposed();
    return _requestPermission(
      Permission.storage,
      'storage',
    );
  }

  Future<bool> hasPhotosPermission() async {
    _ensureNotDisposed();
    return _checkPermissionStatus(Permission.photos);
  }

  Future<bool> requestPhotosPermission() async {
    _ensureNotDisposed();
    return _requestPermission(
      Permission.photos,
      'photos',
    );
  }

  Future<PermissionStatus> getPermissionStatus(Permission permission) async {
    _ensureNotDisposed();

    final cached = _getCachedStatus(permission);
    if (cached != null) {
      return cached;
    }

    try {
      final status = await permission.status.timeout(permissionCheckTimeout);
      _cacheStatus(permission, status);
      return status;
    } on TimeoutException {
      throw PermissionServiceException(
        'Permission status check timed out',
        code: 'STATUS_CHECK_TIMEOUT',
      );
    } catch (e) {
      _logError('getPermissionStatus', e);
      throw PermissionServiceException(
        'Failed to get permission status',
        code: 'GET_STATUS_FAILED',
        originalError: e,
      );
    }
  }

  Future<bool> isPermissionPermanentlyDenied(Permission permission) async {
    _ensureNotDisposed();

    try {
      final status = await getPermissionStatus(permission);
      return status.isPermanentlyDenied;
    } catch (e) {
      _logError('isPermissionPermanentlyDenied', e);
      return false;
    }
  }

  Future<Map<Permission, PermissionStatus>> requestAllPermissions({
    bool includeBackgroundLocation = false,
  }) async {
    _ensureNotDisposed();

    try {
      _logInfo('Requesting all permissions');

      final permissions = <Permission>[
        Permission.location,
        Permission.camera,
        Permission.microphone,
        Permission.notification,
      ];

      if (includeBackgroundLocation) {
        permissions.add(Permission.locationAlways);
      }

      final statuses = await permissions
          .request()
          .timeout(permissionRequestTimeout);

      for (final entry in statuses.entries) {
        _cacheStatus(entry.key, entry.value);
        _logInfo('${entry.key}: ${entry.value}');
      }

      return statuses;
    } on TimeoutException {
      throw PermissionServiceException(
        'Permission request timed out',
        code: 'REQUEST_TIMEOUT',
      );
    } catch (e) {
      _logError('requestAllPermissions', e);
      throw PermissionServiceException(
        'Failed to request all permissions',
        code: 'ALL_PERMISSIONS_FAILED',
        originalError: e,
      );
    }
  }

  Future<Map<Permission, PermissionStatus>> checkAllPermissions({
    bool includeBackgroundLocation = false,
  }) async {
    _ensureNotDisposed();

    try {
      final permissions = <Permission>[
        Permission.location,
        Permission.camera,
        Permission.microphone,
        Permission.notification,
      ];

      if (includeBackgroundLocation) {
        permissions.add(Permission.locationAlways);
      }

      final statuses = <Permission, PermissionStatus>{};

      for (final permission in permissions) {
        final status = await getPermissionStatus(permission);
        statuses[permission] = status;
      }

      return statuses;
    } catch (e) {
      _logError('checkAllPermissions', e);
      throw PermissionServiceException(
        'Failed to check all permissions',
        code: 'CHECK_ALL_FAILED',
        originalError: e,
      );
    }
  }

  Future<bool> areAllCriticalPermissionsGranted() async {
    _ensureNotDisposed();

    try {
      final location = await hasLocationPermission();
      final camera = await hasCameraPermission();
      final microphone = await hasMicrophonePermission();

      return location && camera && microphone;
    } catch (e) {
      _logError('areAllCriticalPermissionsGranted', e);
      return false;
    }
  }

  Future<List<Permission>> getMissingCriticalPermissions() async {
    _ensureNotDisposed();

    final missing = <Permission>[];

    try {
      if (!await hasLocationPermission()) {
        missing.add(Permission.location);
      }
      if (!await hasCameraPermission()) {
        missing.add(Permission.camera);
      }
      if (!await hasMicrophonePermission()) {
        missing.add(Permission.microphone);
      }

      return missing;
    } catch (e) {
      _logError('getMissingCriticalPermissions', e);
      return missing;
    }
  }

  Future<bool> openSettings() async {
    _ensureNotDisposed();

    try {
      _logInfo('Opening app settings');
      final result = await openAppSettings();
      _logInfo('App settings opened: $result');
      return result;
    } catch (e) {
      _logError('openSettings', e);
      return false;
    }
  }

  Future<bool> shouldShowRequestRationale(Permission permission) async {
    _ensureNotDisposed();

    try {
      return await permission.shouldShowRequestRationale;
    } catch (e) {
      _logError('shouldShowRequestRationale', e);
      return false;
    }
  }

  Future<bool> _checkPermissionStatus(Permission permission) async {
    try {
      final status = await getPermissionStatus(permission);
      final granted = status.isGranted;
      
      if (!granted) {
        _logInfo('${permission.toString()} permission not granted: $status');
      }
      
      return granted;
    } catch (e) {
      _logError('_checkPermissionStatus', e);
      return false;
    }
  }

  Future<bool> _requestPermission(
    Permission permission,
    String permissionName,
  ) async {
    return _retryOperation(() async {
      try {
        _logInfo('Requesting $permissionName permission');

        final currentStatus = await getPermissionStatus(permission);

        if (currentStatus.isGranted) {
          _logInfo('$permissionName permission already granted');
          return true;
        }

        if (currentStatus.isPermanentlyDenied) {
          _logWarning('$permissionName permission permanently denied');
          throw PermissionServiceException(
            '$permissionName permission permanently denied. Please enable in settings.',
            code: 'PERMISSION_PERMANENTLY_DENIED',
          );
        }

        final status = await permission
            .request()
            .timeout(permissionRequestTimeout);

        _cacheStatus(permission, status);

        final granted = status.isGranted;
        _logInfo('$permissionName permission request result: ${granted ? 'granted' : 'denied'}');

        if (!granted && status.isPermanentlyDenied) {
          throw PermissionServiceException(
            '$permissionName permission permanently denied. Please enable in settings.',
            code: 'PERMISSION_PERMANENTLY_DENIED',
          );
        }

        return granted;
      } on TimeoutException {
        throw PermissionServiceException(
          '$permissionName permission request timed out',
          code: 'PERMISSION_REQUEST_TIMEOUT',
        );
      } catch (e) {
        _logError('_requestPermission', e);
        if (e is PermissionServiceException) rethrow;
        throw PermissionServiceException(
          'Failed to request $permissionName permission',
          code: 'PERMISSION_REQUEST_FAILED',
          originalError: e,
        );
      }
    });
  }

  Future<T> _retryOperation<T>(Future<T> Function() operation) async {
    int attempts = 0;

    while (attempts < maxRetries) {
      try {
        return await operation();
      } catch (e) {
        attempts++;

        if (e is PermissionServiceException &&
            (e.code == 'PERMISSION_PERMANENTLY_DENIED' ||
             e.code == 'LOCATION_NOT_GRANTED')) {
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

    throw PermissionServiceException(
      'Max retries exceeded',
      code: 'MAX_RETRIES_EXCEEDED',
    );
  }

  PermissionStatus? _getCachedStatus(Permission permission) {
    final cached = _statusCache[permission];
    if (cached == null) return null;

    if (cached.isExpired) {
      _statusCache.remove(permission);
      return null;
    }

    return cached.status;
  }

  void _cacheStatus(Permission permission, PermissionStatus status) {
    _statusCache[permission] = _CachedPermissionStatus(status);
  }

  void clearCache() {
    _statusCache.clear();
    _logInfo('Permission status cache cleared');
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw PermissionServiceException(
        'PermissionService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[PermissionService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[PermissionService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[PermissionService] ERROR in $method: $error');
    }
  }

  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    _statusCache.clear();
    _logInfo('PermissionService disposed');
  }
}

class _CachedPermissionStatus {
  final PermissionStatus status;
  final DateTime cachedAt;

  _CachedPermissionStatus(this.status) : cachedAt = DateTime.now();

  bool get isExpired {
    final now = DateTime.now();
    return now.difference(cachedAt) > PermissionService.statusCacheTTL;
  }
}