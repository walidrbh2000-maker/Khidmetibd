// lib/providers/splash_controller.dart

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/auth_providers.dart';
import '../providers/user_role_provider.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';
import 'core_providers.dart';

// ============================================================================
// ENUMS
// ============================================================================

enum SplashPhase { initializing, animating, ready, error }

enum SplashErrorType { none, noInternet, serverError, timeout, unknown }

// ============================================================================
// STATE
// ============================================================================

class SplashState {
  final SplashPhase phase;
  final SplashErrorType errorType;

  const SplashState({
    this.phase     = SplashPhase.initializing,
    this.errorType = SplashErrorType.none,
  });

  bool get canRetry => phase == SplashPhase.error;

  SplashState copyWith({
    SplashPhase?     phase,
    SplashErrorType? errorType,
  }) {
    return SplashState(
      phase:     phase     ?? this.phase,
      errorType: errorType ?? this.errorType,
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class SplashController extends StateNotifier<SplashState> {
  final Ref _ref;

  bool  _isAnimationComplete  = false;
  bool  _isAuthChecked        = false;
  bool  _isMinDurationElapsed = false;

  bool _isInitializing = false;

  Timer? _minDurationTimer;

  static const Duration _kMinSplashDuration  = Duration(seconds: 3);
  static const Duration _globalInitTimeout   = Duration(seconds: 15);
  static const Duration _kRoleResolveTimeout = Duration(seconds: 5);

  SplashController(this._ref) : super(const SplashState());

  // --------------------------------------------------------------------------
  // Initialization
  // --------------------------------------------------------------------------

  Future<void> initialize() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      if (!_isAnimationComplete) {
        _isAnimationComplete = false;
      }
      _isAuthChecked        = false;
      _isMinDurationElapsed = false;

      _minDurationTimer?.cancel();
      _minDurationTimer = null;

      if (!mounted) return;
      state = const SplashState(phase: SplashPhase.initializing);

      _armMinDurationTimer();

      final authService = _ref.read(authServiceProvider);

      await Future.wait([
        authService.waitForInitialization(),
        Future.delayed(const Duration(seconds: 2)),
      ]).timeout(
        _globalInitTimeout,
        onTimeout: () {
          AppLogger.warning(
            'SplashController.initialize: ${_globalInitTimeout.inSeconds}s '
            'global timeout reached',
          );
          throw TimeoutException(
            'Initialization global timeout',
            _globalInitTimeout,
          );
        },
      );

      if (authService.isLoggedIn && authService.user != null) {
        await _resolveAndCacheRole(authService.user!.uid);
      }

      _isAuthChecked = true;
      _updateState();
    } on TimeoutException {
      AppLogger.warning('SplashController.initialize: timeout');
      if (!mounted) return;
      _isAuthChecked = true;
      state = state.copyWith(
        phase:     SplashPhase.error,
        errorType: SplashErrorType.timeout,
      );
    } on FirebaseException catch (e) {
      AppLogger.error('SplashController.initialize (Firebase)', e);
      if (!mounted) return;
      _isAuthChecked = true;
      state = state.copyWith(
        phase:     SplashPhase.error,
        errorType: _mapFirebaseError(e),
      );
    } catch (e, stack) {
      AppLogger.error('SplashController.initialize', '$e\n$stack');
      if (!mounted) return;
      _isAuthChecked = true;
      state = state.copyWith(
        phase:     SplashPhase.error,
        errorType: SplashErrorType.unknown,
      );
    } finally {
      _isInitializing = false;
    }
  }

  /// Called by SplashScreen when the branding animation finishes.
  void onAnimationComplete() {
    _isAnimationComplete = true;
    _updateState();
  }

  Future<void> retry() => initialize();

  // --------------------------------------------------------------------------
  // Private helpers
  // --------------------------------------------------------------------------

  void _armMinDurationTimer() {
    _minDurationTimer = Timer(_kMinSplashDuration, () {
      if (!mounted) return;
      _isMinDurationElapsed = true;
      _updateState();
    });
  }

  void _updateState() {
    if (!mounted) return;
    if (state.phase == SplashPhase.error) return;

    if (_isAnimationComplete && _isAuthChecked && _isMinDurationElapsed) {
      state = state.copyWith(phase: SplashPhase.ready);
      _ref.read(appInitializedProvider.notifier).state = true;
      _ref.read(authRedirectNotifierProvider).notifyAuthReady();
    } else if (_isAuthChecked && !_isAnimationComplete) {
      state = state.copyWith(phase: SplashPhase.animating);
    }
  }

  Future<void> _resolveAndCacheRole(String uid) async {
    try {
      final firestoreService = _ref.read(firestoreServiceProvider);

      final worker = await firestoreService
          .getWorker(uid)
          .timeout(
            _kRoleResolveTimeout,
            onTimeout: () {
              AppLogger.warning(
                'SplashController._resolveAndCacheRole: '
                '${_kRoleResolveTimeout.inSeconds}s timeout — '
                'falling back to client role for uid=$uid',
              );
              return null;
            },
          );

      final role = worker != null ? UserRole.worker : UserRole.client;

      setCachedUserRole(_ref, role);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PrefKeys.accountRole,
        role == UserRole.worker ? UserType.worker : UserType.user,
      );

      AppLogger.info('SplashController: cached role=$role uid=$uid');
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        AppLogger.error(
          'SplashController._resolveAndCacheRole: PERMISSION_DENIED uid=$uid',
          e,
        );
        rethrow;
      }
      setCachedUserRole(_ref, UserRole.client);
      AppLogger.error('SplashController._resolveAndCacheRole', e);
    } catch (e) {
      setCachedUserRole(_ref, UserRole.client);
      AppLogger.error('SplashController._resolveAndCacheRole', e);
    }
  }

  SplashErrorType _mapFirebaseError(FirebaseException e) {
    switch (e.code) {
      case 'network-request-failed':
        return SplashErrorType.noInternet;
      case 'internal-error':
      case 'unavailable':
      case 'permission-denied':
        return SplashErrorType.serverError;
      case 'deadline-exceeded':
        return SplashErrorType.timeout;
      default:
        return SplashErrorType.unknown;
    }
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final splashControllerProvider =
    StateNotifierProvider.autoDispose<SplashController, SplashState>(
  (ref) => SplashController(ref),
);
