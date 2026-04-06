// lib/providers/notifications_prefs_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/logger.dart';

// ============================================================================
// NOTIFICATION PREFERENCES STATE
// ============================================================================

class NotificationPrefsState {
  final bool isLoading;

  // FIX (P1): added systemPermissionDenied.
  // If OS-level notification permission is blocked, all in-app toggles are
  // silently ineffective. The screen reads this field to show a warning banner.
  // Wire up _load() with FirebaseMessaging.getNotificationSettings() or
  // permission_handler.Permission.notification when integrating.
  final bool systemPermissionDenied;

  final bool newRequests;
  final bool bidReceived;
  final bool chatMessages;
  final bool promotions;

  const NotificationPrefsState({
    this.isLoading              = true,
    this.systemPermissionDenied = false,
    this.newRequests            = true,
    this.bidReceived            = true,
    this.chatMessages           = true,
    this.promotions             = false,
  });

  NotificationPrefsState copyWith({
    bool? isLoading,
    bool? systemPermissionDenied,
    bool? newRequests,
    bool? bidReceived,
    bool? chatMessages,
    bool? promotions,
  }) {
    return NotificationPrefsState(
      isLoading:              isLoading              ?? this.isLoading,
      systemPermissionDenied: systemPermissionDenied ?? this.systemPermissionDenied,
      newRequests:            newRequests            ?? this.newRequests,
      bidReceived:            bidReceived            ?? this.bidReceived,
      chatMessages:           chatMessages           ?? this.chatMessages,
      promotions:             promotions             ?? this.promotions,
    );
  }
}

// ============================================================================
// PREFERENCE KEYS
// ============================================================================

abstract class _Keys {
  static const newRequests  = 'notif_new_requests';
  static const bidReceived  = 'notif_bid_received';
  static const chatMessages = 'notif_chat_messages';
  static const promotions   = 'notif_promotions';
}

// ============================================================================
// NOTIFICATIONS PREFS NOTIFIER
// ============================================================================

class NotificationPrefsNotifier
    extends StateNotifier<NotificationPrefsState> {
  NotificationPrefsNotifier() : super(const NotificationPrefsState()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // TODO: replace `false` with actual OS permission check:
      //   final settings = await FirebaseMessaging.instance
      //       .getNotificationSettings();
      //   final systemDenied = settings.authorizationStatus ==
      //       AuthorizationStatus.denied;
      const bool systemDenied = false;

      if (mounted) {
        state = NotificationPrefsState(
          isLoading:              false,
          systemPermissionDenied: systemDenied,
          newRequests:   prefs.getBool(_Keys.newRequests)  ?? true,
          bidReceived:   prefs.getBool(_Keys.bidReceived)  ?? true,
          chatMessages:  prefs.getBool(_Keys.chatMessages) ?? true,
          promotions:    prefs.getBool(_Keys.promotions)   ?? false,
        );
      }
    } catch (e) {
      AppLogger.error('NotificationPrefsNotifier._load', e);
      if (mounted) state = state.copyWith(isLoading: false);
    }
  }

  Future<void> setNewRequests(bool v) =>
      _set(_Keys.newRequests, v, (s) => s.copyWith(newRequests: v));

  Future<void> setBidReceived(bool v) =>
      _set(_Keys.bidReceived, v, (s) => s.copyWith(bidReceived: v));

  Future<void> setChatMessages(bool v) =>
      _set(_Keys.chatMessages, v, (s) => s.copyWith(chatMessages: v));

  Future<void> setPromotions(bool v) =>
      _set(_Keys.promotions, v, (s) => s.copyWith(promotions: v));

  Future<void> _set(
    String key,
    bool   value,
    NotificationPrefsState Function(NotificationPrefsState) updater,
  ) async {
    // Optimistic update — UI reflects change immediately.
    if (mounted) state = updater(state);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (e) {
      AppLogger.error('NotificationPrefsNotifier._set($key)', e);
    }
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final notificationPrefsProvider = StateNotifierProvider.autoDispose<
    NotificationPrefsNotifier,
    NotificationPrefsState>(
  (ref) => NotificationPrefsNotifier(),
);
