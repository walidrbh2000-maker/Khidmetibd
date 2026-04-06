// lib/providers/login_controller.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/login_state.dart';
import '../providers/auth_providers.dart';
import '../providers/user_role_provider.dart';
import '../services/auth_service.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';
import 'core_providers.dart';

class LoginController extends StateNotifier<LoginState> {
  final AuthService _authService;
  final Ref         _ref;

  LoginController(this._authService, this._ref)
      : super(const LoginState());

  void clearError() {
    if (state.hasError) {
      state = state.copyWith(clearError: true, status: LoginStatus.initial);
    }
  }

  void onEmailChanged(String value) {
    if (state.hasError) {
      state = state.copyWith(
        clearError: true,
        status: LoginStatus.initial,
        email:  value,
      );
    } else {
      state = state.copyWith(email: value);
    }
  }

  // ==========================================================================
  // EMAIL / PASSWORD SIGN-IN
  // ==========================================================================

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    if (state.isLoading) return;

    state = state.copyWith(status: LoginStatus.loading, clearError: true);
    AppLogger.info('LoginController: sign-in attempt for $email');

    await Future.microtask(() {});

    final error = await _authService.signIn(email.trim(), password);

    if (error != null) {
      AppLogger.warning('LoginController: sign-in failed — $error');
      if (mounted) {
        state = state.copyWith(
          status:       LoginStatus.error,
          errorMessage: error,
        );
      }
      return;
    }

    // FIX [A7]: use FirebaseAuth.instance.currentUser?.uid instead of
    // _authService.user?.uid. After signIn() returns, the Firebase Auth
    // SDK has updated currentUser synchronously, but _authService.user is
    // populated by the authStateChanges() stream listener which may not
    // have fired yet on slow devices — causing a null uid and defaulting
    // to client role even for workers.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await _resolveAndPersistRole(uid);
      _ref.read(analyticsServiceProvider).logUserSignedIn(provider: 'email');
    } else {
      setCachedUserRole(_ref, UserRole.client);
      AppLogger.warning('LoginController: uid null after signIn');
    }

    if (!mounted) return;
    state = state.copyWith(status: LoginStatus.success);
    AppLogger.info('LoginController: role resolved, triggering redirect');
    _ref.read(authRedirectNotifierProvider).notifyAuthReady();
  }

  Future<void> resetPassword(String email) async {
    if (email.trim().isEmpty) {
      state = state.copyWith(
        status:       LoginStatus.error,
        errorMessage: 'errors.required_field',
      );
      return;
    }

    state = state.copyWith(status: LoginStatus.loading, clearError: true);
    await Future.microtask(() {});
    final error = await _authService.resetPassword(email.trim());

    if (mounted) {
      state = error != null
          ? state.copyWith(status: LoginStatus.error, errorMessage: error)
          : state.copyWith(status: LoginStatus.initial);
    }
  }

  // ==========================================================================
  // SOCIAL SIGN-IN — Google
  // ==========================================================================

  Future<void> signInWithGoogle() async {
    if (state.isLoading) return;

    state = state.copyWith(status: LoginStatus.loading, clearError: true);
    AppLogger.info('LoginController: Google sign-in attempt');

    await Future.microtask(() {});

    final error = await _authService.signInWithGoogle();

    if (error != null) {
      AppLogger.warning('LoginController: Google sign-in failed — $error');
      if (mounted) {
        state = state.copyWith(status: LoginStatus.error, errorMessage: error);
      }
      return;
    }

    await _postSocialSignIn(provider: 'google');
  }

  // ==========================================================================
  // SOCIAL SIGN-IN — Facebook
  // ==========================================================================

  Future<void> signInWithFacebook() async {
    if (state.isLoading) return;

    state = state.copyWith(status: LoginStatus.loading, clearError: true);
    AppLogger.info('LoginController: Facebook sign-in attempt');

    await Future.microtask(() {});

    final error = await _authService.signInWithFacebook();

    if (error != null) {
      AppLogger.warning('LoginController: Facebook sign-in failed — $error');
      if (mounted) {
        state = state.copyWith(status: LoginStatus.error, errorMessage: error);
      }
      return;
    }

    await _postSocialSignIn(provider: 'facebook');
  }

  // ==========================================================================
  // SOCIAL SIGN-IN — Apple
  // ==========================================================================

  Future<void> signInWithApple() async {
    if (state.isLoading) return;

    state = state.copyWith(status: LoginStatus.loading, clearError: true);
    AppLogger.info('LoginController: Apple sign-in attempt');

    await Future.microtask(() {});

    final error = await _authService.signInWithApple();

    if (error != null) {
      AppLogger.warning('LoginController: Apple sign-in failed — $error');
      if (mounted) {
        state = state.copyWith(status: LoginStatus.error, errorMessage: error);
      }
      return;
    }

    await _postSocialSignIn(provider: 'apple');
  }

  // ==========================================================================
  // SHARED POST-SOCIAL HOOK
  // ==========================================================================

  Future<void> _postSocialSignIn({required String provider}) async {
    // FIX [A7]: read uid directly from FirebaseAuth.instance.currentUser
    // instead of _authService.user. The social sign-in methods in AuthService
    // await signInWithCredential() before returning, so currentUser is already
    // set synchronously by the Firebase SDK at this point. However
    // _authService.user is only updated when the authStateChanges() stream
    // listener fires, which may be deferred by one microtask cycle on slow
    // devices — making _authService.user?.uid transiently null here.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppLogger.info(
          'LoginController: social sign-in cancelled (uid null) — resetting to initial');
      if (mounted) state = state.copyWith(status: LoginStatus.initial);
      return;
    }

    await _resolveAndPersistRole(uid);

    _ref.read(analyticsServiceProvider).logUserSignedIn(provider: provider);

    if (!mounted) return;
    state = state.copyWith(status: LoginStatus.success);
    _ref.read(authRedirectNotifierProvider).notifyAuthReady();
  }

  // ==========================================================================
  // ROLE RESOLUTION
  // ==========================================================================

  Future<void> _resolveAndPersistRole(String uid) async {
    try {
      final firestoreService = _ref.read(firestoreServiceProvider);
      final worker = await firestoreService
          .getWorker(uid)
          .timeout(const Duration(seconds: 10), onTimeout: () => null);

      final role  = worker != null ? UserRole.worker : UserRole.client;
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
        PrefKeys.accountRole,
        role == UserRole.worker ? UserType.worker : UserType.user,
      );

      // FIX (Suggestion 1): use setCachedUserRole helper to respect the
      // write-guard contract — prevents a stale unknown write from overwriting
      // a role that was already resolved by a concurrent call.
      setCachedUserRole(_ref, role, force: true);
      AppLogger.info('LoginController: role=$role uid=$uid');
    } catch (e) {
      AppLogger.error('LoginController._resolveAndPersistRole', e);
      // FIX (QA-04): on network failure, read the previously persisted role.
      try {
        final prefs     = await SharedPreferences.getInstance();
        final persisted = prefs.getString(PrefKeys.accountRole);
        final fallback  = persisted == UserType.worker
            ? UserRole.worker
            : UserRole.client;
        setCachedUserRole(_ref, fallback, force: true);
        AppLogger.warning(
            'LoginController._resolveAndPersistRole: network error — '
            'using persisted role=$persisted');
      } catch (_) {
        setCachedUserRole(_ref, UserRole.client, force: true);
      }
    }
  }
}

final loginControllerProvider =
    StateNotifierProvider.autoDispose<LoginController, LoginState>(
        (ref) {
  return LoginController(ref.read(authServiceProvider), ref);
});
