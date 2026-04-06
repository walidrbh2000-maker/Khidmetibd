// lib/providers/register_controller.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/register_state.dart';
import '../providers/auth_providers.dart';
import '../providers/user_role_provider.dart';
import '../services/auth_service.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';
import 'core_providers.dart';

class RegisterController extends StateNotifier<RegisterState> {
  final AuthService _authService;
  final Ref         _ref;

  RegisterController(this._authService, this._ref)
      : super(const RegisterState());

  void setIsWorker(bool value) {
    state = state.copyWith(isWorker: value, clearService: !value);
  }

  void selectService(String service) {
    state = state.copyWith(selectedService: service);
  }

  void setTermsAccepted(bool value) {
    state = state.copyWith(termsAccepted: value);
  }

  void clearError() {
    if (state.hasError) {
      state = state.copyWith(clearError: true, status: RegisterStatus.initial);
    }
  }

  void onFieldChanged() {
    clearError();
  }

  Future<void> signUp({
    required String fullName,
    required String email,
    required String password,
    required String confirmPassword,
    required String phoneNumber,
  }) async {
    if (state.isLoading) return;

    if (!state.termsAccepted) {
      state = state.copyWith(
        status:       RegisterStatus.error,
        errorMessage: 'register.error.terms_required',
      );
      return;
    }

    if (state.isWorker &&
        (state.selectedService == null || state.selectedService!.isEmpty)) {
      state = state.copyWith(
        status:       RegisterStatus.error,
        errorMessage: 'register.error.service_required',
      );
      return;
    }

    if (password != confirmPassword) {
      state = state.copyWith(
        status:       RegisterStatus.error,
        errorMessage: 'errors.passwords_mismatch',
      );
      return;
    }

    state = state.copyWith(status: RegisterStatus.loading, clearError: true);
    AppLogger.info(
        'RegisterController: attempting registration for $email');

    await Future.microtask(() {});

    final error = await _authService.signUp(
      email:       email.trim(),
      password:    password,
      username:    fullName.trim(),
      phoneNumber: phoneNumber.trim(),
      profession:  state.isWorker ? state.selectedService : null,
      keepLoggedIn: true,
    );

    if (error != null) {
      AppLogger.warning('RegisterController: registration failed — $error');
      if (mounted) {
        state = state.copyWith(
          status:       RegisterStatus.error,
          errorMessage: error,
        );
      }
      return;
    }

    final role = state.isWorker ? UserRole.worker : UserRole.client;
    await _cacheRole(role);

    if (!mounted) return;

    _ref.read(analyticsServiceProvider).logUserRegistered(
      provider: 'email',
      role:     role == UserRole.worker ? 'worker' : 'client',
    );

    AppLogger.info(
        'RegisterController: registration success, role=$role cached');
    state = state.copyWith(status: RegisterStatus.success);

    _ref.read(authRedirectNotifierProvider).notifyAuthReady();
  }

  // ==========================================================================
  // SOCIAL SIGN-IN AS WORKER
  // ==========================================================================

  Future<String?> signInWithSocialAsWorker({
    required String provider,
    required String profession,
  }) async {
    if (state.isLoading) return null;
    if (profession.trim().isEmpty) return 'register.error.service_required';

    if (!state.termsAccepted) {
      state = state.copyWith(
        status:       RegisterStatus.error,
        errorMessage: 'register.error.terms_required',
      );
      return 'register.error.terms_required';
    }

    state = state.copyWith(status: RegisterStatus.loading, clearError: true);
    AppLogger.info(
        'RegisterController: worker social sign-in attempt provider=$provider');

    await Future.microtask(() {});

    final String? authError;
    switch (provider) {
      case 'google':
        authError = await _authService.signInWithGoogle();
        break;
      case 'facebook':
        authError = await _authService.signInWithFacebook();
        break;
      case 'apple':
        authError = await _authService.signInWithApple();
        break;
      default:
        authError = 'errors.sign_in_generic';
    }

    if (authError != null) {
      AppLogger.warning(
          'RegisterController: worker social sign-in failed — $authError');
      if (mounted) {
        state = state.copyWith(
            status: RegisterStatus.error, errorMessage: authError);
      }
      return authError;
    }

    // FIX [A10]: read uid from FirebaseAuth.instance.currentUser instead of
    // _authService.user to avoid transient null after social sign-in.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppLogger.info(
          'RegisterController: worker social sign-in cancelled (uid null)');
      if (mounted) state = state.copyWith(status: RegisterStatus.initial);
      return null;
    }

    // FIX [2/3]: Wrapped linkSocialWorkerProfession in try/catch.
    // Previously an unexpected exception (e.g. network loss mid-flight after
    // social auth succeeded) would propagate unhandled through the controller,
    // leaving the UI stuck in a loading state with no error shown to the user.
    // Now any exception is caught, the state is updated to show an error, and
    // the method returns a localizable error key consistent with the rest of
    // the social sign-in flow.
    String? upgradeError;
    try {
      upgradeError = await _authService.linkSocialWorkerProfession(
        uid:        uid,
        profession: profession,
      );
    } catch (e) {
      AppLogger.error('RegisterController: linkSocialWorkerProfession threw', e);
      if (mounted) {
        state = state.copyWith(
          status:       RegisterStatus.error,
          errorMessage: 'errors.sign_up_generic',
        );
      }
      return 'errors.sign_up_generic';
    }

    if (upgradeError != null) {
      AppLogger.warning(
          'RegisterController: profession link failed — $upgradeError');
      if (mounted) {
        state = state.copyWith(
            status: RegisterStatus.error, errorMessage: upgradeError);
      }
      return upgradeError;
    }

    await _cacheRole(UserRole.worker);

    if (!mounted) return null;

    _ref.read(analyticsServiceProvider).logUserRegistered(
      provider: provider,
      role:     'worker',
    );

    state = state.copyWith(status: RegisterStatus.success);
    AppLogger.info(
        'RegisterController: worker social sign-in complete → redirecting');
    _ref.read(authRedirectNotifierProvider).notifyAuthReady();
    return null;
  }

  // ==========================================================================
  // SOCIAL SIGN-IN AS CLIENT
  // ==========================================================================

  Future<String?> signInWithSocialAsClient({required String provider}) async {
    if (state.isLoading) return null;

    if (!state.termsAccepted) {
      state = state.copyWith(
        status:       RegisterStatus.error,
        errorMessage: 'register.error.terms_required',
      );
      return 'register.error.terms_required';
    }

    state = state.copyWith(status: RegisterStatus.loading, clearError: true);
    AppLogger.info(
        'RegisterController: client social sign-in attempt provider=$provider');

    await Future.microtask(() {});

    final String? authError;
    switch (provider) {
      case 'google':
        authError = await _authService.signInWithGoogle();
        break;
      case 'facebook':
        authError = await _authService.signInWithFacebook();
        break;
      case 'apple':
        authError = await _authService.signInWithApple();
        break;
      default:
        authError = 'errors.sign_in_generic';
    }

    if (authError != null) {
      AppLogger.warning(
          'RegisterController: client social sign-in failed — $authError');
      if (mounted) {
        state = state.copyWith(
            status: RegisterStatus.error, errorMessage: authError);
      }
      return authError;
    }

    // FIX [A10]: read uid from FirebaseAuth.instance.currentUser.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppLogger.info(
          'RegisterController: client social sign-in cancelled (uid null)');
      if (mounted) state = state.copyWith(status: RegisterStatus.initial);
      return null;
    }

    await _cacheRole(UserRole.client);

    if (!mounted) return null;

    _ref.read(analyticsServiceProvider).logUserRegistered(
      provider: provider,
      role:     'client',
    );

    state = state.copyWith(status: RegisterStatus.success);
    AppLogger.info(
        'RegisterController: client social sign-in complete → redirecting');
    _ref.read(authRedirectNotifierProvider).notifyAuthReady();
    return null;
  }

  // ==========================================================================
  // ROLE CACHING
  // ==========================================================================

  Future<void> _cacheRole(UserRole role) async {
    try {
      final isWorker = role == UserRole.worker;

      setCachedUserRole(_ref, role, force: true);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PrefKeys.accountRole,
        isWorker ? UserType.worker : UserType.user,
      );

      AppLogger.info('RegisterController: cached role=$role');
    } catch (e) {
      AppLogger.error('RegisterController._cacheRole', e);
      try {
        final prefs     = await SharedPreferences.getInstance();
        final persisted = prefs.getString(PrefKeys.accountRole);
        final fallback  = persisted == UserType.worker
            ? UserRole.worker
            : UserRole.client;
        setCachedUserRole(_ref, fallback, force: true);
        AppLogger.warning(
            'RegisterController._cacheRole: storage error — '
            'using persisted role=$persisted');
      } catch (_) {
        setCachedUserRole(_ref, UserRole.client, force: true);
      }
    }
  }
}

final registerControllerProvider =
    StateNotifierProvider.autoDispose<RegisterController, RegisterState>(
        (ref) {
  return RegisterController(ref.read(authServiceProvider), ref);
});
