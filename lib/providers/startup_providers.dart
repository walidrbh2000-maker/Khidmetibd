// lib/providers/startup_providers.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/native_channel_service.dart';
import '../services/auth_service.dart';
import 'core_providers.dart';
import 'app_lifecycle_provider.dart' show AppLifecycleNotifier;

// ============================================================================
// LOCATION SERVICE AUTO-START
// ============================================================================

final locationServiceAutoStartProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final authService      = ref.read(authServiceProvider);
  final firestoreService = ref.read(firestoreServiceProvider);
  final nativeService    = ref.read(nativeChannelServiceProvider);

  final user = authService.user;
  if (user == null) {
    _logInfo('locationServiceAutoStart', 'No authenticated user');
    return false;
  }

  try {
    _logInfo('locationServiceAutoStart',
        'Checking worker status for user: ${user.uid}');

    final workerDoc = await firestoreService
        .getWorker(user.uid)
        .timeout(AppLifecycleNotifier.locationServiceStartTimeout);

    if (workerDoc == null) {
      _logInfo('locationServiceAutoStart', 'User is not a worker');
      return false;
    }
    if (!workerDoc.isOnline) {
      _logInfo('locationServiceAutoStart',
          'Worker is offline, skipping location service');
      return false;
    }

    _logInfo('locationServiceAutoStart',
        'Starting location service for online worker');

    final results = await Future.wait([
      nativeService.startLocationService(userId: user.uid, isWorker: true),
      nativeService
          .isIgnoringBatteryOptimizations()
          .timeout(const Duration(seconds: 5)),
    ]);

    _logInfo('locationServiceAutoStart',
        'Location service started successfully');

    final isIgnoring = results[1] as bool;
    if (!isIgnoring) {
      _logWarning(
        'locationServiceAutoStart',
        'Battery optimizations are enabled - may affect background location',
      );
    }

    return true;
  } on TimeoutException {
    _logError('locationServiceAutoStart', 'Operation timed out');
    return false;
  } catch (e) {
    _logError('locationServiceAutoStart', e);
    return false;
  }
});

// ============================================================================
// PERMISSIONS STATUS
// ============================================================================

final permissionsStatusProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final nativeService = ref.read(nativeChannelServiceProvider);
  try {
    _logInfo('permissionsStatus', 'Checking permissions');
    final hasPermissions = await nativeService
        .checkPermissions()
        .timeout(AppLifecycleNotifier.permissionCheckTimeout);
    if (!hasPermissions) {
      _logWarning('permissionsStatus', 'Some permissions are missing');
    } else {
      _logInfo('permissionsStatus', 'All permissions granted');
    }
    return hasPermissions;
  } on TimeoutException {
    _logError('permissionsStatus', 'Permission check timed out');
    return false;
  } catch (e) {
    _logError('permissionsStatus', e);
    return false;
  }
});

// ============================================================================
// BATTERY OPTIMIZATION STATUS
// ============================================================================

final batteryOptimizationStatusProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final nativeService = ref.read(nativeChannelServiceProvider);
  try {
    _logInfo('batteryOptimizationStatus',
        'Checking battery optimization status');
    final isIgnoring = await nativeService
        .isIgnoringBatteryOptimizations()
        .timeout(AppLifecycleNotifier.permissionCheckTimeout);
    if (isIgnoring) {
      _logInfo('batteryOptimizationStatus',
          'Battery optimizations disabled');
    } else {
      _logWarning('batteryOptimizationStatus',
          'Battery optimizations enabled');
    }
    return isIgnoring;
  } on TimeoutException {
    _logError('batteryOptimizationStatus', 'Check timed out');
    return false;
  } catch (e) {
    _logError('batteryOptimizationStatus', e);
    return false;
  }
});

// ============================================================================
// LOCATION SERVICE STATUS
// ============================================================================

final locationServiceStatusProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final nativeService = ref.read(nativeChannelServiceProvider);
  try {
    _logInfo('locationServiceStatus',
        'Checking location service status');
    final isRunning = await nativeService
        .isLocationServiceRunning()
        .timeout(const Duration(seconds: 5));
    _logInfo(
        'locationServiceStatus',
        isRunning
            ? 'Location service is running'
            : 'Location service is not running');
    return isRunning;
  } on TimeoutException {
    _logError('locationServiceStatus', 'Check timed out');
    return false;
  } catch (e) {
    _logError('locationServiceStatus', e);
    return false;
  }
});

// ============================================================================
// LOGGING
// ============================================================================

void _logInfo(String provider, String message) {
  if (kDebugMode) debugPrint('[StartupProviders:$provider] INFO: $message');
}

void _logWarning(String provider, String message) {
  if (kDebugMode) debugPrint('[StartupProviders:$provider] WARNING: $message');
}

void _logError(String provider, dynamic error) {
  if (kDebugMode) debugPrint('[StartupProviders:$provider] ERROR: $error');
}
