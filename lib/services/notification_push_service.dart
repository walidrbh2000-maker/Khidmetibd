// lib/services/notification_push_service.dart

import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'auth_service.dart';
import 'firestore_service.dart';

class NotificationPushServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  NotificationPushServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'NotificationPushServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class NotificationPushService {
  static const Duration tokenOperationTimeout = Duration(seconds: 30);
  static const Duration initializationTimeout = Duration(seconds: 60);
  static const int maxTopicNameLength = 900;
  static const int minTopicNameLength = 1;
  static const int maxRetries = 3;
  static const Duration baseRetryDelay = Duration(seconds: 2);
  static const Duration tokenCacheTTL = Duration(hours: 1);

  static const String topicPattern = r'^[a-zA-Z0-9-_.~%]+$';

  final AuthService authService;
  final FirestoreService firestoreService;
  final FirebaseMessaging _firebaseMessaging;

  StreamSubscription<String>? _tokenRefreshSubscription;
  String? _cachedToken;
  DateTime? _tokenCacheTime;
  bool _isInitialized = false;
  bool _isDisposed = false;

  NotificationPushService(
    this.authService,
    this.firestoreService, {
    FirebaseMessaging? firebaseMessaging,
  }) : _firebaseMessaging = firebaseMessaging ?? FirebaseMessaging.instance;

  bool get isInitialized => _isInitialized && !_isDisposed;
  String? get cachedToken => _hasFreshCachedToken ? _cachedToken : null;

  bool get _hasFreshCachedToken {
    if (_cachedToken == null || _tokenCacheTime == null) {
      return false;
    }
    final age = DateTime.now().difference(_tokenCacheTime!);
    return age < tokenCacheTTL;
  }

  Future<void> initialize() async {
    _ensureNotDisposed();

    if (_isInitialized) {
      _logWarning('NotificationPushService already initialized');
      return;
    }

    try {
      _logInfo('Initializing push notification service');

      await _requestPermissions().timeout(
        initializationTimeout,
        onTimeout: () => throw NotificationPushServiceException(
          'Permission request timed out',
          code: 'PERMISSION_TIMEOUT',
        ),
      );

      await _initializeToken();
      _setupTokenRefreshListener();

      _isInitialized = true;
      _logInfo('Push notification service initialized successfully');
    } catch (e) {
      _isInitialized = false;
      _logError('initialize', e);
      if (e is NotificationPushServiceException) rethrow;
      throw NotificationPushServiceException(
        'Failed to initialize push notifications',
        code: 'INIT_ERROR',
        originalError: e,
      );
    }
  }

  Future<void> _requestPermissions() async {
    try {
      final settings = await _firebaseMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
        criticalAlert: false,
        announcement: false,
      );

      _logInfo(
          'Notification permission status: ${settings.authorizationStatus}');

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        throw NotificationPushServiceException(
          'Notification permissions denied by user',
          code: 'PERMISSION_DENIED',
        );
      }

      if (settings.authorizationStatus ==
          AuthorizationStatus.notDetermined) {
        _logWarning(
          'Notification permissions not yet determined (first install) — '
          'proceeding without blocking. Token will be saved once permissions '
          'are granted.',
        );
        return;
      }

      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus !=
              AuthorizationStatus.provisional) {
        _logWarning(
            'Notification permissions not fully authorized: ${settings.authorizationStatus}');
      }
    } catch (e) {
      _logError('_requestPermissions', e);
      if (e is NotificationPushServiceException) rethrow;
      throw NotificationPushServiceException(
        'Failed to request notification permissions',
        code: 'PERMISSION_REQUEST_FAILED',
        originalError: e,
      );
    }
  }

  Future<void> _initializeToken() async {
    try {
      final token = await getToken();

      if (token == null) {
        _logWarning('Failed to retrieve FCM token during initialization');
        return;
      }

      await _saveFcmToken(token);
    } catch (e) {
      _logError('_initializeToken', e);
      throw NotificationPushServiceException(
        'Failed to initialize FCM token',
        code: 'TOKEN_INIT_FAILED',
        originalError: e,
      );
    }
  }

  void _setupTokenRefreshListener() {
    _tokenRefreshSubscription?.cancel();

    try {
      _tokenRefreshSubscription = _firebaseMessaging.onTokenRefresh.listen(
        (token) {
          _logInfo('FCM token refreshed');
          _updateCachedToken(token);
          _saveFcmToken(token);
        },
        onError: (error) {
          _logError('tokenRefreshStream', error);
        },
      );

      _logInfo('Token refresh listener setup complete');
    } catch (e) {
      _logError('_setupTokenRefreshListener', e);
    }
  }

  /// FIX (Critical): writes FCM token to both the `users` collection and,
  /// if the authenticated user is a worker, to the `workers` collection.
  /// Workers will now receive push notifications for bids, job starts, and
  /// completions.
  Future<void> _saveFcmToken(String token) async {
    if (token.trim().isEmpty) {
      _logWarning('Attempted to save empty FCM token');
      return;
    }

    try {
      final user = authService.user;
      if (user == null) {
        _logWarning('Cannot save FCM token: user not authenticated');
        return;
      }

      // Always update the users collection.
      await firestoreService.updateFcmToken(user.uid, token);
      _logInfo('FCM token saved for user: ${user.uid}');

      // FIX: also update the workers collection if the user is a worker.
      final worker = await firestoreService.getWorker(user.uid);
      if (worker != null) {
        await firestoreService.updateWorkerFcmToken(user.uid, token);
        _logInfo('FCM token saved for worker: ${user.uid}');
      }
    } catch (e) {
      _logError('_saveFcmToken', e);
    }
  }

  Future<String?> getToken({bool forceRefresh = false}) async {
    _ensureNotDisposed();

    if (!forceRefresh && _hasFreshCachedToken) {
      _logInfo('Returning cached FCM token');
      return _cachedToken;
    }

    return _retryOperation(() async {
      try {
        _logInfo('Fetching FCM token');

        final token = await _firebaseMessaging
            .getToken()
            .timeout(tokenOperationTimeout);

        if (token == null) {
          _logWarning('FCM token is null');
          return null;
        }

        _updateCachedToken(token);
        _logInfo('FCM token retrieved: ${_maskToken(token)}');

        return token;
      } on TimeoutException {
        throw NotificationPushServiceException(
          'Token retrieval timed out',
          code: 'TOKEN_TIMEOUT',
        );
      } catch (e) {
        _logError('getToken', e);
        if (e is NotificationPushServiceException) rethrow;
        throw NotificationPushServiceException(
          'Failed to get FCM token',
          code: 'GET_TOKEN_FAILED',
          originalError: e,
        );
      }
    });
  }

  Future<void> subscribeToTopic(String topic) async {
    _ensureNotDisposed();
    _validateTopicName(topic);

    return _retryOperation(() async {
      try {
        _logInfo('Subscribing to topic: $topic');

        await _firebaseMessaging
            .subscribeToTopic(topic)
            .timeout(tokenOperationTimeout);

        _logInfo('Successfully subscribed to topic: $topic');
      } on TimeoutException {
        throw NotificationPushServiceException(
          'Topic subscription timed out: $topic',
          code: 'SUBSCRIBE_TIMEOUT',
        );
      } catch (e) {
        _logError('subscribeToTopic', e);
        throw NotificationPushServiceException(
          'Failed to subscribe to topic: $topic',
          code: 'SUBSCRIBE_ERROR',
          originalError: e,
        );
      }
    });
  }

  Future<void> unsubscribeFromTopic(String topic) async {
    _ensureNotDisposed();
    _validateTopicName(topic);

    return _retryOperation(() async {
      try {
        _logInfo('Unsubscribing from topic: $topic');

        await _firebaseMessaging
            .unsubscribeFromTopic(topic)
            .timeout(tokenOperationTimeout);

        _logInfo('Successfully unsubscribed from topic: $topic');
      } on TimeoutException {
        throw NotificationPushServiceException(
          'Topic unsubscription timed out: $topic',
          code: 'UNSUBSCRIBE_TIMEOUT',
        );
      } catch (e) {
        _logError('unsubscribeFromTopic', e);
        throw NotificationPushServiceException(
          'Failed to unsubscribe from topic: $topic',
          code: 'UNSUBSCRIBE_ERROR',
          originalError: e,
        );
      }
    });
  }

  Future<void> deleteToken() async {
    _ensureNotDisposed();

    return _retryOperation(() async {
      try {
        _logInfo('Deleting FCM token');

        await _firebaseMessaging
            .deleteToken()
            .timeout(tokenOperationTimeout);

        _clearCachedToken();
        _logInfo('FCM token deleted successfully');
      } on TimeoutException {
        throw NotificationPushServiceException(
          'Token deletion timed out',
          code: 'DELETE_TOKEN_TIMEOUT',
        );
      } catch (e) {
        _logError('deleteToken', e);
        throw NotificationPushServiceException(
          'Failed to delete FCM token',
          code: 'DELETE_TOKEN_FAILED',
          originalError: e,
        );
      }
    });
  }

  Future<void> setForegroundNotificationPresentationOptions({
    bool alert = true,
    bool badge = true,
    bool sound = true,
  }) async {
    _ensureNotDisposed();

    try {
      await _firebaseMessaging.setForegroundNotificationPresentationOptions(
        alert: alert,
        badge: badge,
        sound: sound,
      );

      _logInfo(
          'Foreground notification options set: alert=$alert, badge=$badge, sound=$sound');
    } catch (e) {
      _logError('setForegroundNotificationPresentationOptions', e);
      throw NotificationPushServiceException(
        'Failed to set foreground notification options',
        code: 'SET_OPTIONS_FAILED',
        originalError: e,
      );
    }
  }

  Future<bool> isSupported() async {
    try {
      return await _firebaseMessaging.isSupported();
    } catch (e) {
      _logError('isSupported', e);
      return false;
    }
  }

  Future<NotificationSettings> getNotificationSettings() async {
    _ensureNotDisposed();

    try {
      return await _firebaseMessaging.getNotificationSettings();
    } catch (e) {
      _logError('getNotificationSettings', e);
      throw NotificationPushServiceException(
        'Failed to get notification settings',
        code: 'GET_SETTINGS_FAILED',
        originalError: e,
      );
    }
  }

  void _validateTopicName(String topic) {
    if (topic.trim().isEmpty) {
      throw NotificationPushServiceException(
        'Topic name cannot be empty',
        code: 'INVALID_TOPIC_NAME',
      );
    }

    if (topic.length < minTopicNameLength ||
        topic.length > maxTopicNameLength) {
      throw NotificationPushServiceException(
        'Topic name length must be between $minTopicNameLength and $maxTopicNameLength characters',
        code: 'INVALID_TOPIC_LENGTH',
      );
    }

    if (!RegExp(topicPattern).hasMatch(topic)) {
      throw NotificationPushServiceException(
        'Topic name contains invalid characters. Use only: a-z A-Z 0-9 - _ . ~ %',
        code: 'INVALID_TOPIC_CHARACTERS',
      );
    }

    if (topic.startsWith('/topics/')) {
      throw NotificationPushServiceException(
        'Topic name should not include the /topics/ prefix',
        code: 'INVALID_TOPIC_PREFIX',
      );
    }
  }

  void _updateCachedToken(String token) {
    _cachedToken = token;
    _tokenCacheTime = DateTime.now();
  }

  void _clearCachedToken() {
    _cachedToken = null;
    _tokenCacheTime = null;
  }

  String _maskToken(String token) {
    if (token.length <= 20) {
      return '${token.substring(0, (token.length / 2).floor())}...';
    }
    return '${token.substring(0, 20)}...';
  }

  Future<T> _retryOperation<T>(Future<T> Function() operation) async {
    int attempts = 0;

    while (attempts < maxRetries) {
      try {
        return await operation();
      } catch (e) {
        attempts++;

        if (e is NotificationPushServiceException &&
            (e.code?.contains('TIMEOUT') ?? false)) {
          if (attempts >= maxRetries) rethrow;
        } else if (attempts >= maxRetries) {
          rethrow;
        }

        final delay = baseRetryDelay * attempts;
        _logWarning('Retry $attempts/$maxRetries after ${delay.inSeconds}s');
        await Future.delayed(delay);
      }
    }

    throw NotificationPushServiceException(
      'Max retries exceeded',
      code: 'MAX_RETRIES_EXCEEDED',
    );
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw NotificationPushServiceException(
        'NotificationPushService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[NotificationPushService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode)
      debugPrint('[NotificationPushService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[NotificationPushService] ERROR in $method: $error');
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;

    _isDisposed = true;
    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _clearCachedToken();
    _isInitialized = false;
    _logInfo('NotificationPushService disposed');
  }
}