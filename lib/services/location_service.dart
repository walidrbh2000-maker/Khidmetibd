// lib/services/location_service.dart

import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:location/location.dart' as loc;

class LocationServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  LocationServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'LocationServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class LocationService {
  static const Duration positionTimeout = Duration(seconds: 10);
  static const Duration lastPositionCacheTTL = Duration(minutes: 5);
  static const Duration _requestServiceTimeout = Duration(seconds: 30);
  static const LocationAccuracy defaultAccuracy = LocationAccuracy.high;
  static const int defaultDistanceFilter = 10;
  static const int minDistanceFilter = 0;
  static const int maxDistanceFilter = 1000;
  static const double minLatitude = -90.0;
  static const double maxLatitude = 90.0;
  static const double minLongitude = -180.0;
  static const double maxLongitude = 180.0;

  StreamSubscription<Position>? _positionStreamSubscription;
  Position? _lastPosition;
  DateTime? _lastPositionTimestamp;
  bool _isStreaming = false;
  bool _isDisposed = false;

  // The `location` package instance — used exclusively for the in-app
  // GPS enable dialog. All positioning still goes through geolocator.
  final loc.Location _locationPlugin = loc.Location();

  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();

  Stream<Position> get positionStream => _positionController.stream;
  Position? get lastPosition => _lastPosition;
  bool get isStreaming => _isStreaming && !_isDisposed;
  bool get isDisposed => _isDisposed;
  DateTime? get lastPositionTimestamp => _lastPositionTimestamp;

  bool get hasRecentPosition {
    if (_lastPosition == null || _lastPositionTimestamp == null) {
      return false;
    }
    final age = DateTime.now().difference(_lastPositionTimestamp!);
    return age < lastPositionCacheTTL;
  }

  // --------------------------------------------------------------------------
  // Location service (GPS hardware) checks
  // --------------------------------------------------------------------------

  Future<bool> isLocationServiceEnabled() async {
    _ensureNotDisposed();
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (e) {
      _logError('isLocationServiceEnabled', e);
      return false;
    }
  }

  /// Shows the Google Play Services **in-app dialog** (Image 2) that asks the
  /// user to enable GPS / location accuracy — without leaving the app.
  ///
  /// Returns `true` if the user tapped "Activer", `false` if they tapped
  /// "Non, merci", and `null` on any error.
  ///
  /// On iOS this silently falls back to [openLocationSettings] because the
  /// platform dialog is not available via this API.
  Future<bool> requestLocationService() async {
    _ensureNotDisposed();
    try {
      _logInfo('Requesting location service via in-app dialog');

      // `_locationPlugin.requestService()` triggers the ResolvableApiException
      // Google dialog — exactly the one shown in Image 2.
      final enabled = await _locationPlugin.requestService()
          .timeout(_requestServiceTimeout);

      _logInfo('requestLocationService result: $enabled');
      return enabled;
    } on TimeoutException {
      _logError('requestLocationService', 'timeout after ${_requestServiceTimeout.inSeconds}s');
      // Graceful fallback: open the OS settings page.
      try {
        await Geolocator.openLocationSettings();
      } catch (_) {}
      return false;
    } catch (e) {
      _logError('requestLocationService', e);
      // Graceful fallback: open the OS settings page.
      try {
        await Geolocator.openLocationSettings();
      } catch (_) {}
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // Permission checks (delegated to geolocator)
  // --------------------------------------------------------------------------

  Future<LocationPermission> checkPermission() async {
    _ensureNotDisposed();
    try {
      return await Geolocator.checkPermission();
    } catch (e) {
      _logError('checkPermission', e);
      return LocationPermission.denied;
    }
  }

  Future<LocationPermission> requestPermission() async {
    _ensureNotDisposed();
    try {
      final permission = await Geolocator.requestPermission();
      _logInfo('Permission request result: $permission');
      return permission;
    } catch (e) {
      _logError('requestPermission', e);
      throw LocationServiceException(
        'Failed to request location permission',
        code: 'PERMISSION_REQUEST_FAILED',
        originalError: e,
      );
    }
  }

  // --------------------------------------------------------------------------
  // Positioning
  // --------------------------------------------------------------------------

  Future<Position> getCurrentPosition({
    LocationAccuracy accuracy = defaultAccuracy,
    bool forceRefresh = false,
  }) async {
    _ensureNotDisposed();

    if (!forceRefresh && hasRecentPosition) {
      _logInfo('Returning cached position');
      return _lastPosition!;
    }

    try {
      final serviceEnabled = await isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw LocationServiceException(
          'Location service is disabled. Please enable location services.',
          code: 'SERVICE_DISABLED',
        );
      }

      await _ensurePermissionGranted();

      _logInfo('Getting current position with accuracy: $accuracy');
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: accuracy,
        timeLimit: positionTimeout,
      ).timeout(
        positionTimeout,
        onTimeout: () => throw LocationServiceException(
          'Position request timed out',
          code: 'POSITION_TIMEOUT',
        ),
      );

      _validatePosition(position);
      _updateLastPosition(position);

      return position;
    } on TimeoutException {
      throw LocationServiceException(
        'Position request timed out',
        code: 'POSITION_TIMEOUT',
      );
    } catch (e) {
      if (e is LocationServiceException) rethrow;
      _logError('getCurrentPosition', e);
      throw LocationServiceException(
        'Failed to get current position',
        code: 'GET_POSITION_FAILED',
        originalError: e,
      );
    }
  }

  Future<Position?> getLastKnownPosition() async {
    _ensureNotDisposed();
    try {
      final position = await Geolocator.getLastKnownPosition();
      if (position != null) {
        _validatePosition(position);
        _updateLastPosition(position);
        _logInfo('Retrieved last known position');
      } else {
        _logInfo('No last known position available');
      }
      return position;
    } catch (e) {
      _logError('getLastKnownPosition', e);
      return null;
    }
  }

  Future<void> startPositionStream({
    LocationAccuracy accuracy = defaultAccuracy,
    int distanceFilter = defaultDistanceFilter,
  }) async {
    _ensureNotDisposed();

    if (_isStreaming) {
      _logWarning('Position stream already started');
      return;
    }

    _validateDistanceFilter(distanceFilter);

    try {
      await _ensurePermissionGranted();

      final locationSettings = LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        timeLimit: positionTimeout,
      );

      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        _onPositionUpdate,
        onError: _onPositionError,
        cancelOnError: false,
      );

      _isStreaming = true;
      _logInfo(
          'Position stream started (accuracy: $accuracy, distanceFilter: ${distanceFilter}m)');
    } catch (e) {
      _isStreaming = false;
      _logError('startPositionStream', e);
      if (e is LocationServiceException) rethrow;
      throw LocationServiceException(
        'Failed to start position stream',
        code: 'STREAM_START_FAILED',
        originalError: e,
      );
    }
  }

  Future<void> stopPositionStream() async {
    if (!_isStreaming) return;
    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    _isStreaming = false;
    _logInfo('Position stream stopped');
  }

  double distanceBetween({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) {
    _ensureNotDisposed();
    _validateCoordinates(startLatitude, startLongitude);
    _validateCoordinates(endLatitude, endLongitude);

    try {
      return Geolocator.distanceBetween(
        startLatitude,
        startLongitude,
        endLatitude,
        endLongitude,
      );
    } catch (e) {
      _logError('distanceBetween', e);
      throw LocationServiceException(
        'Failed to calculate distance',
        code: 'DISTANCE_CALCULATION_FAILED',
        originalError: e,
      );
    }
  }

  double bearingBetween({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) {
    _ensureNotDisposed();
    _validateCoordinates(startLatitude, startLongitude);
    _validateCoordinates(endLatitude, endLongitude);

    try {
      return Geolocator.bearingBetween(
        startLatitude,
        startLongitude,
        endLatitude,
        endLongitude,
      );
    } catch (e) {
      _logError('bearingBetween', e);
      throw LocationServiceException(
        'Failed to calculate bearing',
        code: 'BEARING_CALCULATION_FAILED',
        originalError: e,
      );
    }
  }

  /// Opens the OS **location settings** page (leaves the app).
  /// Prefer [requestLocationService] for the in-app dialog.
  Future<bool> openLocationSettings() async {
    _ensureNotDisposed();
    try {
      final result = await Geolocator.openLocationSettings();
      _logInfo('Location settings opened: $result');
      return result;
    } catch (e) {
      _logError('openLocationSettings', e);
      return false;
    }
  }

  Future<bool> openAppSettings() async {
    _ensureNotDisposed();
    try {
      final result = await Geolocator.openAppSettings();
      _logInfo('App settings opened: $result');
      return result;
    } catch (e) {
      _logError('openAppSettings', e);
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // Internal helpers
  // --------------------------------------------------------------------------

  void _onPositionUpdate(Position position) {
    if (_isDisposed) return;
    try {
      _validatePosition(position);
      _updateLastPosition(position);
      _positionController.add(position);
      _logInfo(
        'Position update: (${position.latitude.toStringAsFixed(6)}, '
        '${position.longitude.toStringAsFixed(6)}) '
        'accuracy: ${position.accuracy.toStringAsFixed(1)}m',
      );
    } catch (e) {
      _logError('_onPositionUpdate', e);
      _positionController.addError(e);
    }
  }

  void _onPositionError(dynamic error) {
    if (_isDisposed) return;
    _logError('positionStream', error);
    _positionController.addError(error);
    if (error is LocationServiceDisabledException) {
      _logWarning('Location service disabled, stopping stream');
      stopPositionStream();
    }
  }

  void _updateLastPosition(Position position) {
    _lastPosition = position;
    _lastPositionTimestamp = DateTime.now();
  }

  Future<void> _ensurePermissionGranted() async {
    var permission = await checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw LocationServiceException(
        'Location permission denied',
        code: 'PERMISSION_DENIED',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw LocationServiceException(
        'Location permission permanently denied. Please enable in app settings.',
        code: 'PERMISSION_DENIED_FOREVER',
      );
    }
  }

  void _validatePosition(Position position) {
    _validateCoordinates(position.latitude, position.longitude);
    if (position.accuracy < 0) {
      throw LocationServiceException(
        'Invalid position accuracy: ${position.accuracy}',
        code: 'INVALID_ACCURACY',
      );
    }
    if (position.accuracy > 100) {
      _logWarning(
          'Low accuracy position: ${position.accuracy.toStringAsFixed(1)}m');
    }
  }

  void _validateCoordinates(double latitude, double longitude) {
    if (latitude < minLatitude || latitude > maxLatitude) {
      throw LocationServiceException(
        'Invalid latitude: $latitude',
        code: 'INVALID_LATITUDE',
      );
    }
    if (longitude < minLongitude || longitude > maxLongitude) {
      throw LocationServiceException(
        'Invalid longitude: $longitude',
        code: 'INVALID_LONGITUDE',
      );
    }
  }

  void _validateDistanceFilter(int distanceFilter) {
    if (distanceFilter < minDistanceFilter ||
        distanceFilter > maxDistanceFilter) {
      throw LocationServiceException(
        'Invalid distance filter: $distanceFilter',
        code: 'INVALID_DISTANCE_FILTER',
      );
    }
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw LocationServiceException(
        'LocationService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void clearCache() {
    _lastPosition = null;
    _lastPositionTimestamp = null;
    _logInfo('Position cache cleared');
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[LocationService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[LocationService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) debugPrint('[LocationService] ERROR in $method: $error');
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await stopPositionStream();
    await _positionController.close();
    _lastPosition = null;
    _lastPositionTimestamp = null;
    _logInfo('LocationService disposed');
  }
}
