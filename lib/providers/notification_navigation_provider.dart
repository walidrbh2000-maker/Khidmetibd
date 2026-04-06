// lib/providers/notification_navigation_provider.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_lifecycle_provider.dart'; // for AppLifecycleNotifier.navigationTimeout

// ============================================================================
// NOTIFICATION NAVIGATION STATE
// ============================================================================

class NotificationNavigationState {
  final String?               type;
  final Map<String, dynamic>? data;
  final DateTime?             timestamp;

  const NotificationNavigationState({
    this.type,
    this.data,
    this.timestamp,
  });

  NotificationNavigationState copyWith({
    String?               type,
    Map<String, dynamic>? data,
    DateTime?             timestamp,
  }) {
    return NotificationNavigationState(
      type:      type      ?? this.type,
      data:      data      ?? this.data,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  bool get hasNavigation => type != null && data != null;

  bool get isExpired {
    if (timestamp == null) return true;
    return DateTime.now().difference(timestamp!) >
        AppLifecycleNotifier.navigationTimeout;
  }

  @override
  String toString() =>
      'NotificationNavigationState(type: $type, hasData: ${data != null}, '
      'timestamp: $timestamp)';
}

// ============================================================================
// NOTIFICATION NAVIGATION NOTIFIER
// ============================================================================

class NotificationNavigationNotifier
    extends StateNotifier<NotificationNavigationState> {
  Timer? _expirationTimer;

  NotificationNavigationNotifier()
      : super(const NotificationNavigationState()) {
    _logInfo('NotificationNavigationNotifier initialized');
  }

  void handleNotificationTap(Map<String, dynamic> data) {
    if (!mounted) {
      _logWarning('Attempted to handle notification tap after disposal');
      return;
    }
    if (data.isEmpty) {
      _logWarning('Received empty notification data');
      return;
    }

    try {
      final type = data['type'] as String?;
      if (type == null || type.trim().isEmpty) {
        _logWarning('Notification data missing type field');
        return;
      }
      _logInfo('Handling notification tap: type=$type');
      state = NotificationNavigationState(
        type:      type,
        data:      Map<String, dynamic>.from(data),
        timestamp: DateTime.now(),
      );
      _scheduleExpiration();
    } catch (e) {
      _logError('handleNotificationTap', e);
    }
  }

  void clearNavigation() {
    if (!mounted) return;
    if (state.hasNavigation) _logInfo('Clearing notification navigation');
    _cancelExpirationTimer();
    state = const NotificationNavigationState();
  }

  void _scheduleExpiration() {
    _cancelExpirationTimer();
    _expirationTimer = Timer(
      AppLifecycleNotifier.navigationTimeout,
      () {
        if (mounted && state.hasNavigation) {
          _logInfo('Navigation expired, clearing');
          clearNavigation();
        }
      },
    );
  }

  void _cancelExpirationTimer() {
    _expirationTimer?.cancel();
    _expirationTimer = null;
  }

  void _logInfo(String message) {
    if (kDebugMode) {
      debugPrint('[NotificationNavigation] INFO: $message');
    }
  }

  void _logWarning(String message) {
    if (kDebugMode) {
      debugPrint('[NotificationNavigation] WARNING: $message');
    }
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[NotificationNavigation] ERROR in $method: $error');
    }
  }

  @override
  void dispose() {
    _cancelExpirationTimer();
    _logInfo('NotificationNavigationNotifier disposed');
    super.dispose();
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final notificationNavigationProvider = StateNotifierProvider<
    NotificationNavigationNotifier,
    NotificationNavigationState>(
  (ref) => NotificationNavigationNotifier(),
);
