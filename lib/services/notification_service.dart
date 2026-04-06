// lib/services/notification_service.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/notification_model.dart';

class NotificationServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  NotificationServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'NotificationServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

enum NotificationPriority {
  min,
  low,
  defaultPriority,
  high,
  max,
}

class NotificationService {
  static const String generalChannelId         = 'general_channel';
  static const String generalChannelName       = 'General Notifications';
  static const String generalChannelDescription = 'General app notifications';

  static const String messagesChannelId         = 'messages_channel';
  static const String messagesChannelName       = 'Messages';
  static const String messagesChannelDescription = 'Chat messages';

  static const String serviceRequestsChannelId          = 'service_requests_channel';
  static const String serviceRequestsChannelName        = 'Service Requests';
  static const String serviceRequestsChannelDescription = 'Service request notifications';

  static const String iconName               = '@mipmap/ic_launcher';
  static const Duration operationTimeout     = Duration(seconds: 10);
  static const int maxNotificationIdValue    = 2147483647;
  static const int maxTitleLength            = 100;
  static const int maxBodyLength             = 500;

  final FlutterLocalNotificationsPlugin _notifications;

  bool _isInitialized = false;
  bool _isDisposed    = false;
  Function(String?)? _onSelectNotification;

  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _notifications = plugin ?? FlutterLocalNotificationsPlugin();

  bool get isInitialized => _isInitialized && !_isDisposed;

  Future<void> initialize({
    required Function(String?) onSelectNotification,
  }) async {
    _ensureNotDisposed();

    if (_isInitialized) {
      _logWarning('NotificationService already initialized');
      return;
    }

    try {
      _logInfo('Initializing notification service');

      _onSelectNotification = onSelectNotification;

      const androidSettings = AndroidInitializationSettings(iconName);
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS:     iosSettings,
      );

      final initialized = await _notifications
          .initialize(
            initSettings,
            onDidReceiveNotificationResponse: _handleNotificationResponse,
          )
          .timeout(
            operationTimeout,
            onTimeout: () => throw NotificationServiceException(
              'Notification initialization timed out',
              code: 'INIT_TIMEOUT',
            ),
          );

      if (initialized == false) {
        throw NotificationServiceException(
          'Notification initialization returned false',
          code: 'INIT_FAILED',
        );
      }

      await _createNotificationChannels();
      _isInitialized = true;
      _logInfo('Notification service initialized successfully');
    } catch (e) {
      _isInitialized = false;
      _logError('initialize', e);
      if (e is NotificationServiceException) rethrow;
      throw NotificationServiceException(
        'Failed to initialize notification service',
        code: 'INIT_ERROR',
        originalError: e,
      );
    }
  }

  Future<void> _createNotificationChannels() async {
    if (!defaultTargetPlatform.toString().contains('android')) return;

    try {
      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin == null) {
        _logWarning('Android plugin not available for channel creation');
        return;
      }

      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          generalChannelId,
          generalChannelName,
          description: generalChannelDescription,
          importance:  Importance.defaultImportance,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          messagesChannelId,
          messagesChannelName,
          description:     messagesChannelDescription,
          importance:      Importance.high,
          enableVibration: true,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          serviceRequestsChannelId,
          serviceRequestsChannelName,
          description:     serviceRequestsChannelDescription,
          importance:      Importance.high,
          enableVibration: true,
        ),
      );

      _logInfo('Notification channels created');
    } catch (e) {
      _logError('_createNotificationChannels', e);
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    if (_isDisposed) {
      _logWarning('Received notification response after disposal');
      return;
    }
    try {
      _logInfo('Notification tapped: ${response.payload ?? "no payload"}');
      _onSelectNotification?.call(response.payload);
    } catch (e) {
      _logError('_handleNotificationResponse', e);
    }
  }

  Future<bool> requestPermissions() async {
    _ensureNotDisposed();
    try {
      _logInfo('Requesting notification permissions');

      if (defaultTargetPlatform == TargetPlatform.android) {
        final androidPlugin = _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin == null) {
          _logWarning('Android plugin not available');
          return false;
        }
        final result = await androidPlugin.requestNotificationsPermission();
        _logInfo('Android notification permission: ${result ?? false}');
        return result ?? false;
      }

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final iosPlugin = _notifications
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>();
        if (iosPlugin == null) {
          _logWarning('iOS plugin not available');
          return false;
        }
        final result = await iosPlugin.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        _logInfo('iOS notification permission: ${result ?? false}');
        return result ?? false;
      }

      return false;
    } catch (e) {
      _logError('requestPermissions', e);
      return false;
    }
  }

  Future<void> showNotification({
    required int    id,
    required String title,
    required String body,
    String?                payload,
    NotificationPriority   priority  = NotificationPriority.defaultPriority,
    String?                channelId,
  }) async {
    _ensureNotDisposed();
    _ensureInitialized();
    _validateNotificationId(id);
    _validateNotificationContent(title, body);

    try {
      final effectiveChannelId = channelId ?? generalChannelId;

      final androidDetails = AndroidNotificationDetails(
        effectiveChannelId,
        _getChannelName(effectiveChannelId),
        channelDescription: _getChannelDescription(effectiveChannelId),
        importance:         _mapPriorityToImportance(priority),
        priority:           Priority.high,
        showWhen:           true,
        enableVibration:    true,
        playSound:          true,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS:     iosDetails,
      );

      await _notifications
          .show(id, title, body, details, payload: payload)
          .timeout(
            operationTimeout,
            onTimeout: () => throw NotificationServiceException(
              'Notification display timed out',
              code: 'SHOW_TIMEOUT',
            ),
          );

      _logInfo('Notification shown (ID: $id): $title');
    } catch (e) {
      _logError('showNotification', e);
      if (e is NotificationServiceException) rethrow;
      throw NotificationServiceException(
        'Failed to show notification',
        code:          'SHOW_ERROR',
        originalError: e,
      );
    }
  }

  // FIX (L10n P1): The `title` parameter is now required instead of optional.
  //
  // Previously the method accepted an optional `title` and fell back to the
  // hardcoded French string "Nouveau message de $senderName" when omitted.
  // This meant every caller that did NOT pass a title showed a French string
  // to all users regardless of their locale setting.
  //
  // Now callers MUST pass a localized title. Obtain it before calling this
  // method — e.g. from a Cloud Function that knows the target user's locale,
  // or from AppLocalizations if you have a context available.
  //
  // Migration for existing callers:
  //   BEFORE: showMessageNotification(conversationId: id, senderName: name, message: msg)
  //   AFTER:  showMessageNotification(
  //             conversationId: id,
  //             senderName: name,
  //             message: msg,
  //             title: localizedTitle,  // e.g. 'New message from $name'
  //           )
  Future<void> showMessageNotification({
    required String conversationId,
    required String senderName,
    required String message,
    required String title,
  }) async {
    _ensureNotDisposed();
    _ensureInitialized();

    if (conversationId.trim().isEmpty) {
      throw NotificationServiceException(
        'Conversation ID cannot be empty',
        code: 'INVALID_CONVERSATION_ID',
      );
    }
    if (senderName.trim().isEmpty) {
      throw NotificationServiceException(
        'Sender name cannot be empty',
        code: 'INVALID_SENDER_NAME',
      );
    }
    if (message.trim().isEmpty) {
      throw NotificationServiceException(
        'Message cannot be empty',
        code: 'INVALID_MESSAGE',
      );
    }
    if (title.trim().isEmpty) {
      throw NotificationServiceException(
        'Title cannot be empty — pass a localized title string',
        code: 'INVALID_TITLE',
      );
    }

    final notificationId = _generateNotificationId(conversationId);

    await showNotification(
      id:        notificationId,
      title:     title,
      body:      _truncateMessage(message),
      payload:   'message:$conversationId',
      priority:  NotificationPriority.high,
      channelId: messagesChannelId,
    );
  }

  Future<void> showServiceRequestNotification({
    required String requestId,
    required String title,
    required String message,
  }) async {
    _ensureNotDisposed();
    _ensureInitialized();

    if (requestId.trim().isEmpty) {
      throw NotificationServiceException(
        'Request ID cannot be empty',
        code: 'INVALID_REQUEST_ID',
      );
    }
    if (title.trim().isEmpty) {
      throw NotificationServiceException(
        'Title cannot be empty',
        code: 'INVALID_TITLE',
      );
    }
    if (message.trim().isEmpty) {
      throw NotificationServiceException(
        'Message cannot be empty',
        code: 'INVALID_MESSAGE',
      );
    }

    final notificationId = _generateNotificationId(requestId);

    await showNotification(
      id:        notificationId,
      title:     title,
      body:      _truncateMessage(message),
      payload:   'service_request:$requestId',
      priority:  NotificationPriority.high,
      channelId: serviceRequestsChannelId,
    );
  }

  Future<void> cancelNotification(int id) async {
    _ensureNotDisposed();
    _validateNotificationId(id);
    try {
      await _notifications.cancel(id);
      _logInfo('Notification cancelled (ID: $id)');
    } catch (e) {
      _logError('cancelNotification', e);
    }
  }

  Future<void> cancelAllNotifications() async {
    _ensureNotDisposed();
    try {
      await _notifications.cancelAll();
      _logInfo('All notifications cancelled');
    } catch (e) {
      _logError('cancelAllNotifications', e);
    }
  }

  Future<List<PendingNotificationRequest>> getPendingNotifications() async {
    _ensureNotDisposed();
    try {
      final pending = await _notifications.pendingNotificationRequests();
      _logInfo('Retrieved ${pending.length} pending notifications');
      return pending;
    } catch (e) {
      _logError('getPendingNotifications', e);
      return [];
    }
  }

  Future<List<ActiveNotification>> getActiveNotifications() async {
    _ensureNotDisposed();
    try {
      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin == null) {
        _logWarning('Android plugin not available');
        return [];
      }
      final active = await androidPlugin.getActiveNotifications();
      _logInfo('Retrieved ${active.length} active notifications');
      return active;
    } catch (e) {
      _logError('getActiveNotifications', e);
      return [];
    }
  }

  int _generateNotificationId(String key) =>
      key.hashCode.abs() % maxNotificationIdValue;

  String _truncateMessage(String message, {int maxLength = 200}) {
    if (message.length <= maxLength) return message;
    return '${message.substring(0, maxLength)}...';
  }

  String _getChannelName(String channelId) {
    switch (channelId) {
      case messagesChannelId:         return messagesChannelName;
      case serviceRequestsChannelId:  return serviceRequestsChannelName;
      default:                        return generalChannelName;
    }
  }

  String _getChannelDescription(String channelId) {
    switch (channelId) {
      case messagesChannelId:         return messagesChannelDescription;
      case serviceRequestsChannelId:  return serviceRequestsChannelDescription;
      default:                        return generalChannelDescription;
    }
  }

  Importance _mapPriorityToImportance(NotificationPriority priority) {
    switch (priority) {
      case NotificationPriority.min:             return Importance.min;
      case NotificationPriority.low:             return Importance.low;
      case NotificationPriority.defaultPriority: return Importance.defaultImportance;
      case NotificationPriority.high:            return Importance.high;
      case NotificationPriority.max:             return Importance.max;
    }
  }

  void _validateNotificationId(int id) {
    if (id < 0 || id > maxNotificationIdValue) {
      throw NotificationServiceException(
        'Invalid notification ID: $id',
        code: 'INVALID_NOTIFICATION_ID',
      );
    }
  }

  void _validateNotificationContent(String title, String body) {
    if (title.trim().isEmpty) {
      throw NotificationServiceException(
        'Notification title cannot be empty',
        code: 'INVALID_TITLE',
      );
    }
    if (body.trim().isEmpty) {
      throw NotificationServiceException(
        'Notification body cannot be empty',
        code: 'INVALID_BODY',
      );
    }
    if (title.length > maxTitleLength) {
      throw NotificationServiceException(
        'Notification title too long: ${title.length} chars (max $maxTitleLength)',
        code: 'TITLE_TOO_LONG',
      );
    }
    if (body.length > maxBodyLength) {
      throw NotificationServiceException(
        'Notification body too long: ${body.length} chars (max $maxBodyLength)',
        code: 'BODY_TOO_LONG',
      );
    }
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw NotificationServiceException(
        'NotificationService not initialized. Call initialize() first.',
        code: 'NOT_INITIALIZED',
      );
    }
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw NotificationServiceException(
        'NotificationService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[NotificationService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[NotificationService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[NotificationService] ERROR in $method: $error');
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _onSelectNotification = null;
    _isInitialized = false;
    _logInfo('NotificationService disposed');
  }
}
