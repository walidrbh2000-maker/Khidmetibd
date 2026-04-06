// lib/services/native_channel_service.dart

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class NativeChannelServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  NativeChannelServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'NativeChannelServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class NativeChannelService {
  static const String _channelName = 'com.khidmeti.app/native';
  static const Duration _methodCallTimeout = Duration(seconds: 10);
  static const int _maxRetries = 2;

  static const String _methodCheckPermissions = 'checkPermissions';
  static const String _methodRequestPermissions = 'requestPermissions';
  static const String _methodRequestLocationPermission = 'requestLocationPermission';
  static const String _methodRequestBackgroundLocationPermission = 'requestBackgroundLocationPermission';
  static const String _methodRequestNotificationPermission = 'requestNotificationPermission';
  static const String _methodIsIgnoringBatteryOptimizations = 'isIgnoringBatteryOptimizations';
  static const String _methodRequestIgnoreBatteryOptimizations = 'requestIgnoreBatteryOptimizations';
  static const String _methodStartLocationService = 'startLocationService';
  static const String _methodStopLocationService = 'stopLocationService';
  static const String _methodIsLocationServiceRunning = 'isLocationServiceRunning';
  static const String _methodShowNotification = 'showNotification';
  static const String _methodCancelAllNotifications = 'cancelAllNotifications';
  static const String _methodOnNotificationTapped = 'onNotificationTapped';

  final MethodChannel _channel;

  Function(Map<String, dynamic>)? onNotificationTapped;

  bool _isDisposed = false;
  bool _isHandlerSetup = false;

  NativeChannelService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _setupMethodCallHandler();
  }

  void _setupMethodCallHandler() {
    if (_isHandlerSetup) {
      _logWarning('Method call handler already setup');
      return;
    }

    try {
      _channel.setMethodCallHandler(_handleMethodCall);
      _isHandlerSetup = true;
      _logInfo('Method call handler setup complete');
    } catch (e) {
      _logError('_setupMethodCallHandler', e);
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (_isDisposed) {
      _logWarning('Received method call after disposal: ${call.method}');
      return null;
    }

    try {
      switch (call.method) {
        case _methodOnNotificationTapped:
          _handleNotificationTapped(call.arguments);
          break;
        default:
          _logWarning('Unknown method call: ${call.method}');
      }
    } catch (e) {
      _logError('_handleMethodCall', e);
    }

    return null;
  }

  void _handleNotificationTapped(dynamic arguments) {
    if (onNotificationTapped == null) {
      _logWarning('Notification tapped but no handler registered');
      return;
    }

    try {
      if (arguments is! Map) {
        _logError('_handleNotificationTapped',
            'Invalid arguments type: ${arguments.runtimeType}');
        return;
      }

      final data = Map<String, dynamic>.from(arguments);
      onNotificationTapped!(data);
      _logInfo('Notification tap handled: ${data.keys.join(", ")}');
    } catch (e) {
      _logError('_handleNotificationTapped', e);
    }
  }

  // =========================================================================
  // PERMISSION METHODS
  // =========================================================================

  Future<bool> checkPermissions() async {
    _ensureNotDisposed();

    return _invokeMethodWithRetry<bool>(
      method: _methodCheckPermissions,
      defaultValue: false,
      operation: 'check permissions',
    );
  }

  Future<bool> requestPermissions() async {
    _ensureNotDisposed();

    return _invokeMethodWithRetry<bool>(
      method: _methodRequestPermissions,
      defaultValue: false,
      operation: 'request permissions',
      throwOnError: true,
    );
  }

  Future<bool> requestLocationPermission() async {
    _ensureNotDisposed();

    return _invokeMethodWithRetry<bool>(
      method: _methodRequestLocationPermission,
      defaultValue: false,
      operation: 'request location permission',
      throwOnError: true,
    );
  }

  Future<bool> requestBackgroundLocationPermission() async {
    _ensureNotDisposed();

    return _invokeMethodWithRetry<bool>(
      method: _methodRequestBackgroundLocationPermission,
      defaultValue: false,
      operation: 'request background location permission',
      throwOnError: true,
    );
  }

  Future<bool> requestNotificationPermission() async {
    _ensureNotDisposed();

    return _invokeMethodWithRetry<bool>(
      method: _methodRequestNotificationPermission,
      defaultValue: false,
      operation: 'request notification permission',
      throwOnError: true,
    );
  }

  // =========================================================================
  // BATTERY OPTIMIZATION METHODS
  // =========================================================================

  Future<bool> isIgnoringBatteryOptimizations() async {
    _ensureNotDisposed();

    return _invokeMethodWithRetry<bool>(
      method: _methodIsIgnoringBatteryOptimizations,
      defaultValue: false,
      operation: 'check battery optimizations',
    );
  }

  Future<bool> requestIgnoreBatteryOptimizations() async {
    _ensureNotDisposed();

    return _invokeMethodWithRetry<bool>(
      method: _methodRequestIgnoreBatteryOptimizations,
      defaultValue: false,
      operation: 'request ignore battery optimizations',
      throwOnError: true,
    );
  }

  // =========================================================================
  // LOCATION SERVICE METHODS
  // =========================================================================

  Future<void> startLocationService({
    required String userId,
    required bool isWorker,
  }) async {
    _ensureNotDisposed();
    _validateUserId(userId);

    try {
      await _invokeMethodWithTimeout(
        _methodStartLocationService,
        arguments: {
          'userId': userId,
          'isWorker': isWorker,
        },
      );

      _logInfo(
          'Location service started for user: $userId (${isWorker ? 'worker' : 'client'})');
    } catch (e) {
      _logError('startLocationService', e);
      if (e is NativeChannelServiceException) rethrow;
      throw NativeChannelServiceException(
        'Failed to start location service',
        code: 'START_LOCATION_FAILED',
        originalError: e,
      );
    }
  }

  Future<void> stopLocationService() async {
    _ensureNotDisposed();

    try {
      await _invokeMethodWithTimeout(_methodStopLocationService);
      _logInfo('Location service stopped');
    } catch (e) {
      _logError('stopLocationService', e);
      if (e is NativeChannelServiceException) rethrow;
      throw NativeChannelServiceException(
        'Failed to stop location service',
        code: 'STOP_LOCATION_FAILED',
        originalError: e,
      );
    }
  }

  Future<bool> isLocationServiceRunning() async {
    _ensureNotDisposed();

    return _invokeMethodWithRetry<bool>(
      method: _methodIsLocationServiceRunning,
      defaultValue: false,
      operation: 'check location service status',
    );
  }

  // =========================================================================
  // NOTIFICATION METHODS
  // =========================================================================

  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    _ensureNotDisposed();
    _validateNotificationInput(title, body);

    try {
      await _invokeMethodWithTimeout(
        _methodShowNotification,
        arguments: {
          'title': title,
          'body': body,
          if (payload != null) 'payload': payload,
        },
      );

      _logInfo('Notification shown: $title');
    } catch (e) {
      _logError('showNotification', e);
    }
  }

  Future<void> cancelAllNotifications() async {
    _ensureNotDisposed();

    try {
      await _invokeMethodWithTimeout(_methodCancelAllNotifications);
      _logInfo('All notifications cancelled');
    } catch (e) {
      _logError('cancelAllNotifications', e);
    }
  }

  // =========================================================================
  // HELPER METHODS
  // =========================================================================

  Future<T> _invokeMethodWithTimeout<T>(
    String method, {
    dynamic arguments,
  }) async {
    try {
      final result = await _channel
          .invokeMethod<T>(method, arguments)
          .timeout(_methodCallTimeout);

      return result as T;
    } on TimeoutException {
      throw NativeChannelServiceException(
        'Method call timed out: $method',
        code: 'METHOD_TIMEOUT',
      );
    } on PlatformException catch (e) {
      throw NativeChannelServiceException(
        'Platform exception in $method: ${e.message}',
        code: e.code,
        originalError: e,
      );
    } catch (e) {
      throw NativeChannelServiceException(
        'Failed to invoke method: $method',
        code: 'METHOD_INVOCATION_FAILED',
        originalError: e,
      );
    }
  }

  Future<T> _invokeMethodWithRetry<T>({
    required String method,
    dynamic arguments,
    required T defaultValue,
    required String operation,
    bool throwOnError = false,
  }) async {
    int attempts = 0;

    while (attempts <= _maxRetries) {
      try {
        final result = await _channel
            .invokeMethod<T>(method, arguments)
            .timeout(_methodCallTimeout);

        final value = result ?? defaultValue;

        if (attempts > 0) {
          _logInfo('$operation succeeded after $attempts retries');
        }

        return value;
      } on TimeoutException catch (e) {
        attempts++;
        if (attempts > _maxRetries) {
          _logError(method, 'Timeout after $attempts attempts');
          if (throwOnError) {
            throw NativeChannelServiceException(
              'Failed to $operation: timeout',
              code: 'TIMEOUT',
              originalError: e,
            );
          }
          return defaultValue;
        }
        _logWarning('$operation timed out, retrying ($attempts/$_maxRetries)');
        final delayMs = 500 * attempts;
        await Future.delayed(Duration(milliseconds: delayMs));
        // FIX (Performance P1): check _isDisposed after every retry delay.
        // If the service was disposed while we were waiting, abort immediately
        // instead of making another channel call that would throw anyway.
        if (_isDisposed) return defaultValue;
      } on PlatformException catch (e) {
        _logError(method, 'Platform exception: ${e.message}');
        if (throwOnError) {
          throw NativeChannelServiceException(
            'Failed to $operation: ${e.message}',
            code: e.code,
            originalError: e,
          );
        }
        return defaultValue;
      } catch (e) {
        _logError(method, e);
        if (throwOnError) {
          throw NativeChannelServiceException(
            'Failed to $operation',
            code: 'OPERATION_FAILED',
            originalError: e,
          );
        }
        return defaultValue;
      }
    }

    return defaultValue;
  }

  void _validateUserId(String userId) {
    if (userId.trim().isEmpty) {
      throw NativeChannelServiceException(
        'User ID cannot be empty',
        code: 'INVALID_USER_ID',
      );
    }
  }

  void _validateNotificationInput(String title, String body) {
    if (title.trim().isEmpty) {
      throw NativeChannelServiceException(
        'Notification title cannot be empty',
        code: 'INVALID_NOTIFICATION_TITLE',
      );
    }

    if (body.trim().isEmpty) {
      throw NativeChannelServiceException(
        'Notification body cannot be empty',
        code: 'INVALID_NOTIFICATION_BODY',
      );
    }
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw NativeChannelServiceException(
        'NativeChannelService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[NativeChannelService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[NativeChannelService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[NativeChannelService] ERROR in $method: $error');
    }
  }

  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    onNotificationTapped = null;
    _logInfo('NativeChannelService disposed');
  }
}
