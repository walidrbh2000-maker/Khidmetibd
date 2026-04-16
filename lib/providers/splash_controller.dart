// lib/providers/splash_controller.dart
//
// MIGRATION NOTE:
//   - waitForInitialization() now relies on FirebaseAuth.authStateChanges()
//     directly — no dependency on the email auth flow.
//   - Onboarding check added: if the user has never seen the onboarding slides,
//     the router goes to /onboarding regardless of auth state.
//   - Email verification check removed — phone auth users are always verified.
//   - _resolveAndCacheRole logic unchanged (getUser → isWorker).

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/auth_providers.dart';
import '../providers/onboarding_controller.dart';
import '../providers/user_role_provider.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';
import 'core_providers.dart';

// ── Enums ──────────────────────────────────────────────────────────────────

enum SplashPhase { initializing, animating, ready, error }
enum SplashErrorType { none, noInternet, serverError, timeout, unknown }

// ── State ──────────────────────────────────────────────────────────────────

class SplashState {
  final SplashPhase     phase;
  final SplashErrorType errorType;

  const SplashState({
    this.phase     = SplashPhase.initializing,
    this.errorType = SplashErrorType.none,
  });

  bool get canRetry => phase == SplashPhase.error;

  SplashState copyWith({SplashPhase? phase, SplashErrorType? errorType}) {
    return SplashState(
      phase:     phase     ?? this.phase,
      errorType: errorType ?? this.errorType,
    );
  }
}

// ── Controller ─────────────────────────────────────────────────────────────

class SplashController extends StateNotifier<SplashState> {
  final Ref _ref;

  bool _isAnimationComplete  = false;
  bool _isAuthChecked        = false;
  bool _isMinDurationElapsed = false;
  bool _isInitializing       = false;

  Timer? _minDurationTimer;

  static const Duration _kMinSplashDuration  = Duration(seconds: 3);
  static const Duration _globalInitTimeout   = Duration(seconds: 15);
  static const Duration _kRoleResolveTimeout = Duration(seconds: 5);
  static const Duration _kAuthStateTimeout   = Duration(seconds: 10);

  SplashController(this._ref) : super(const SplashState());

  // ── Initialization ─────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      _isAuthChecked        = false;
      _isMinDurationElapsed = false;
      _minDurationTimer?.cancel();

      if (!mounted) return;
      state = const SplashState(phase: SplashPhase.initializing);

      _armMinDurationTimer();

      // Wait for Firebase auth state to resolve + onboarding state to load.
      await Future.wait([
        _waitForAuthState(),
        _waitForOnboarding(),
        Future.delayed(const Duration(seconds: 2)),
      ]).timeout(
        _globalInitTimeout,
        onTimeout: () {
          AppLogger.warning('SplashController: global timeout');
          throw TimeoutException('Splash init timeout', _globalInitTimeout);
        },
      );

      // If user is logged in, resolve their role.
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        await _resolveAndCacheRole(currentUser.uid);
      }

      _isAuthChecked = true;
      _updateState();
    } on TimeoutException {
      AppLogger.warning('SplashController: timeout');
      if (!mounted) return;
      _isAuthChecked = true;
      state = state.copyWith(
        phase:     SplashPhase.error,
        errorType: SplashErrorType.timeout,
      );
    } on FirebaseException catch (e) {
      AppLogger.error('SplashController (Firebase)', e);
      if (!mounted) return;
      _isAuthChecked = true;
      state = state.copyWith(
        phase:     SplashPhase.error,
        errorType: _mapFirebaseError(e),
      );
    } catch (e, stack) {
      AppLogger.error('SplashController', '$e\n$stack');
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

  void onAnimationComplete() {
    _isAnimationComplete = true;
    _updateState();
  }

  Future<void> retry() => initialize();

  // ── Private helpers ─────────────────────────────────────────────────────

  Future<void> _waitForAuthState() async {
    try {
      await FirebaseAuth.instance
          .authStateChanges()
          .first
          .timeout(_kAuthStateTimeout, onTimeout: () => null);
    } catch (e) {
      AppLogger.warning('SplashController: auth state timeout — continuing');
    }
  }

  Future<void> _waitForOnboarding() async {
    // OnboardingController loads SharedPrefs asynchronously.
    // We poll until isLoaded to prevent a flash of the onboarding screen
    // for returning users.
    const maxWait  = Duration(seconds: 2);
    const interval = Duration(milliseconds: 50);
    final start    = DateTime.now();

    final ctrl = _ref.read(onboardingControllerProvider.notifier);
    while (!ctrl.isLoaded) {
      if (DateTime.now().difference(start) > maxWait) break;
      await Future.delayed(interval);
    }
  }

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

  /// Resolves whether the user is a worker or client and caches the result.
  /// Uses GET /users/:uid — the unified collection with `role` field.
  Future<void> _resolveAndCacheRole(String uid) async {
    try {
      final firestoreService = _ref.read(firestoreServiceProvider);

      final userDoc = await firestoreService
          .getUser(uid)
          .timeout(_kRoleResolveTimeout, onTimeout: () => null);

      final role = userDoc?.isWorker == true ? UserRole.worker : UserRole.client;

      setCachedUserRole(_ref, role);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PrefKeys.accountRole,
        role == UserRole.worker ? UserType.worker : UserType.user,
      );

      AppLogger.info('SplashController: cached role=$role uid=$uid');
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        AppLogger.error('SplashController: PERMISSION_DENIED uid=$uid', e);
        rethrow;
      }
      setCachedUserRole(_ref, UserRole.client);
    } catch (e) {
      setCachedUserRole(_ref, UserRole.client);
      AppLogger.error('SplashController._resolveAndCacheRole', e);
    }
  }

  SplashErrorType _mapFirebaseError(FirebaseException e) {
    switch (e.code) {
      case 'network-request-failed': return SplashErrorType.noInternet;
      case 'internal-error':
      case 'unavailable':
      case 'permission-denied':      return SplashErrorType.serverError;
      case 'deadline-exceeded':      return SplashErrorType.timeout;
      default:                       return SplashErrorType.unknown;
    }
  }

  @override
  void dispose() {
    _minDurationTimer?.cancel();
    super.dispose();
  }
}

// ── Provider ───────────────────────────────────────────────────────────────

final splashControllerProvider =
    StateNotifierProvider.autoDispose<SplashController, SplashState>(
  (ref) => SplashController(ref),
);
