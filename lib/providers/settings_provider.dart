// lib/providers/settings_provider.dart
//
// MOVED FROM: lib/screens/settings/settings_provider.dart
//
// STATE FIX (P2): collapsed isSigningOut: bool + isDeletingAccount: bool into
// SettingsStatus enum variants (signingOut, deletingAccount). Consumers that
// already used state.isSigningOut / state.isDeletingAccount continue to work
// via backward-compat getters on SettingsState.
//
// FIX (Settings Audit P1): SettingsNotifier was calling
// FirebaseAnalytics.instance.logEvent() directly from the state layer.
// Fix: replaced with ref.read(analyticsServiceProvider) calls.
//
// FIX [AUTO] deleteAccount — FCM tokens cleared before Auth deletion.
// FIX [AUTO] deleteAccount — prefs.clear() moved after confirmed deletion so
//   re-authentication (requires-recent-login) leaves prefs intact and the
//   account remains accessible.
// FIX [AUTO] deleteAccount — prefs.clear() replaced with targeted key removal
//   so unrelated local preferences (theme, locale, etc.) survive.
//
// FIX [L1] signOut — prefs.remove(PrefKeys.accountRole) moved AFTER
//   authService.signOut() succeeds. Previously it was called BEFORE signOut,
//   meaning that if signOut threw an exception the role pref was already wiped
//   — leaving the user in a broken state where the app thought they were a
//   client even though they were still authenticated as a worker.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_providers.dart';
import 'core_providers.dart';
import 'user_role_provider.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';

// ============================================================================
// SETTINGS STATE
// ============================================================================

// FIX (P2): extended with signingOut + deletingAccount to replace the separate
// boolean fields. SettingsStatus.loading is now reserved for profile load only.
enum SettingsStatus { idle, loading, signingOut, deletingAccount, error }

class SettingsState {
  final SettingsStatus status;
  final String? userName;
  final String? professionLabel;
  final String? profileImageUrl;
  final UserRole activeRole;
  final bool isWorkerAccount;

  final double? workerAverageRating;
  final int?    workerRatingCount;

  final String? errorMessage;

  const SettingsState({
    this.status              = SettingsStatus.loading,
    this.userName,
    this.professionLabel,
    this.profileImageUrl,
    this.activeRole          = UserRole.client,
    this.isWorkerAccount     = false,
    this.workerAverageRating,
    this.workerRatingCount,
    this.errorMessage,
  });

  // ── Backward-compat getters — settings_screen / settings_content unchanged ─

  /// True while a sign-out operation is in progress.
  bool get isSigningOut => status == SettingsStatus.signingOut;

  /// True while an account-deletion operation is in progress.
  bool get isDeletingAccount => status == SettingsStatus.deletingAccount;

  // ─────────────────────────────────────────────────────────────────────────

  SettingsState copyWith({
    SettingsStatus? status,
    String?  userName,
    String?  professionLabel,
    String?  profileImageUrl,
    UserRole? activeRole,
    bool?    isWorkerAccount,
    double?  workerAverageRating,
    int?     workerRatingCount,
    String?  errorMessage,
  }) {
    return SettingsState(
      status:              status              ?? this.status,
      userName:            userName            ?? this.userName,
      professionLabel:     professionLabel     ?? this.professionLabel,
      profileImageUrl:     profileImageUrl     ?? this.profileImageUrl,
      activeRole:          activeRole          ?? this.activeRole,
      isWorkerAccount:     isWorkerAccount     ?? this.isWorkerAccount,
      workerAverageRating: workerAverageRating ?? this.workerAverageRating,
      workerRatingCount:   workerRatingCount   ?? this.workerRatingCount,
      errorMessage:        errorMessage,
    );
  }
}

// ============================================================================
// SETTINGS NOTIFIER
// ============================================================================

class SettingsNotifier extends StateNotifier<SettingsState> {
  final Ref _ref;

  SettingsNotifier(this._ref) : super(const SettingsState()) {
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    try {
      final authService      = _ref.read(authServiceProvider);
      final firestoreService = _ref.read(firestoreServiceProvider);
      final uid              = authService.user?.uid;

      if (uid == null) {
        state = state.copyWith(
          status:       SettingsStatus.error,
          errorMessage: 'errors.no_user',
        );
        return;
      }

      final prefs            = await SharedPreferences.getInstance();
      final savedAccountRole = prefs.getString(PrefKeys.accountRole);

      // Fast path: accountRole already cached.
      if (savedAccountRole == UserType.worker) {
        final firebaseUser = authService.user;
        state = state.copyWith(
          status:          SettingsStatus.idle,
          userName:        firebaseUser?.displayName ?? '',
          activeRole:      UserRole.worker,
          isWorkerAccount: true,
        );

        final worker = await firestoreService.getWorker(uid);
        if (worker != null && mounted) {
          state = state.copyWith(
            userName:            worker.name,
            professionLabel:     worker.profession,
            profileImageUrl:     worker.profileImageUrl,
            workerAverageRating: worker.averageRating,
            workerRatingCount:   worker.ratingCount,
          );
        }
        AppLogger.info('Settings loaded: worker (cached)');
        return;
      }

      // Slow path: check Firestore.
      final worker = await firestoreService.getWorker(uid);
      if (worker != null) {
        await prefs.setString(PrefKeys.accountRole, UserType.worker);
        if (mounted) {
          state = state.copyWith(
            status:              SettingsStatus.idle,
            userName:            worker.name,
            professionLabel:     worker.profession,
            profileImageUrl:     worker.profileImageUrl,
            activeRole:          UserRole.worker,
            isWorkerAccount:     true,
            workerAverageRating: worker.averageRating,
            workerRatingCount:   worker.ratingCount,
          );
        }
        AppLogger.info('Settings loaded: worker (Firestore)');
        return;
      }

      final user = await firestoreService.getUser(uid);
      if (user != null && mounted) {
        state = state.copyWith(
          status:          SettingsStatus.idle,
          userName:        user.name,
          activeRole:      UserRole.client,
          isWorkerAccount: false,
        );
        AppLogger.info('Settings loaded: client');
        return;
      }

      final firebaseUser = authService.user;
      if (mounted) {
        state = state.copyWith(
          status:          SettingsStatus.idle,
          userName:        firebaseUser?.displayName ?? '',
          activeRole:      UserRole.client,
          isWorkerAccount: false,
        );
      }
    } catch (e, st) {
      AppLogger.error('SettingsNotifier._loadProfileData', e, st);
      if (mounted) {
        state = state.copyWith(
          status:       SettingsStatus.error,
          errorMessage: 'errors.load_failed',
        );
      }
    }
  }

  /// Signs the user out with a clean teardown sequence.
  ///
  /// FIX (P2): status: SettingsStatus.signingOut replaces isSigningOut: true.
  /// FIX: isSigningOut guard prevents double-tap race condition.
  /// FIX: FCM token cleared from Firestore before sign-out.
  /// FIX (Settings Audit P1): replaced FirebaseAnalytics.instance.logEvent()
  ///   with ref.read(analyticsServiceProvider).logUserSignedOut().
  /// FIX [L1]: prefs.remove(PrefKeys.accountRole) moved AFTER
  ///   authService.signOut() succeeds. Previously it was before signOut, so
  ///   any exception from signOut left the pref wiped while the user was still
  ///   authenticated — causing a client-role fallback on the next cold launch
  ///   even for authenticated workers. Now the pref is only removed once
  ///   sign-out is confirmed; on failure it is left intact and the role is
  ///   restored in the catch block.
  Future<void> signOut() async {
    if (!mounted) return;
    // Guard: use compat getter — reads status == SettingsStatus.signingOut
    if (state.isSigningOut) return;

    // FIX (P2): single status field replaces the former isSigningOut bool.
    state = state.copyWith(status: SettingsStatus.signingOut);

    final cachedRoleNotifier = _ref.read(cachedUserRoleProvider.notifier);
    final authService        = _ref.read(authServiceProvider);
    final firestoreService   = _ref.read(firestoreServiceProvider);
    final uid                = authService.user?.uid;

    _ref.read(analyticsServiceProvider).logUserSignedOut(
      accountType: state.isWorkerAccount ? 'worker' : 'client',
    );

    try {
      cachedRoleNotifier.state = UserRole.unknown;

      if (uid != null) {
        try {
          await firestoreService.updateUserFcmToken(uid, '');
          if (state.isWorkerAccount) {
            await firestoreService.updateWorkerFcmToken(uid, '');
          }
          AppLogger.info('FCM token cleared for uid: $uid');
        } catch (fcmError) {
          AppLogger.warning('FCM cleanup failed: $fcmError');
        }
      }

      // FIX [L1]: authService.signOut() is called BEFORE prefs.remove so
      // that if signOut throws (e.g. network error), prefs remain intact and
      // the user can retry without losing their locally-cached role.
      await authService.signOut();

      // Pref removed only after confirmed sign-out success.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(PrefKeys.accountRole);
      } catch (prefsError) {
        // Non-fatal — the auth session is already ended; stale pref is
        // harmless and will be overwritten on the next successful sign-in.
        AppLogger.warning('signOut: prefs.remove failed — $prefsError');
      }

    } catch (e) {
      AppLogger.error('SettingsNotifier.signOut', e);

      if (mounted) {
        cachedRoleNotifier.state = state.isWorkerAccount
            ? UserRole.worker
            : UserRole.client;
        // FIX (P2): restore idle + error (no separate isSigningOut: false needed)
        state = state.copyWith(
          status:       SettingsStatus.error,
          errorMessage: 'errors.signout_failed',
        );
      }
    }
  }

  /// Permanently deletes the Firebase Auth account and wipes local state.
  ///
  /// FIX (P2): status: SettingsStatus.deletingAccount replaces isDeletingAccount: true.
  /// FIX (Settings Audit P1): replaced FirebaseAnalytics.instance.logEvent()
  ///   with ref.read(analyticsServiceProvider).logUserDeletedAccount().
  /// FIX [AUTO]: FCM tokens cleared before Auth deletion (best-effort).
  /// FIX [AUTO]: prefs cleared AFTER confirmed deletion so requires-recent-login
  ///   errors leave the account accessible with prefs intact.
  /// FIX [AUTO]: prefs.clear() replaced with targeted key removal — only
  ///   auth/account keys are wiped; unrelated prefs (theme, locale, etc.) survive.
  Future<String?> deleteAccount() async {
    if (!mounted) return null;
    // Guard: use compat getter — reads status == SettingsStatus.deletingAccount
    if (state.isDeletingAccount) return null;

    // FIX (P2): single status field replaces the former isDeletingAccount bool.
    state = state.copyWith(status: SettingsStatus.deletingAccount);

    final cachedRoleNotifier = _ref.read(cachedUserRoleProvider.notifier);
    final authService        = _ref.read(authServiceProvider);
    final firestoreService   = _ref.read(firestoreServiceProvider);
    final uid                = authService.user?.uid;

    _ref.read(analyticsServiceProvider).logUserDeletedAccount(
      accountType: state.isWorkerAccount ? 'worker' : 'client',
    );

    try {
      cachedRoleNotifier.state = UserRole.unknown;

      // FIX [AUTO]: clear FCM tokens from Firestore before deleting the Auth
      // account. This is best-effort — a failure here does not abort deletion,
      // but Cloud Function cleanup (idempotent) is the authoritative backstop.
      if (uid != null) {
        try {
          await firestoreService.updateUserFcmToken(uid, '');
          if (state.isWorkerAccount) {
            await firestoreService.updateWorkerFcmToken(uid, '');
          }
          AppLogger.info(
              'SettingsNotifier.deleteAccount: FCM tokens cleared uid=$uid');
        } catch (fcmError) {
          AppLogger.warning(
              'SettingsNotifier.deleteAccount: FCM cleanup failed — $fcmError');
        }
      }

      // FIX [AUTO]: attempt deletion BEFORE clearing prefs. If Auth requires
      // re-authentication (requires-recent-login), the error is returned here
      // and prefs remain intact so the user stays logged in and can retry.
      final errorKey = await authService.deleteAccount();
      if (errorKey != null) {
        if (mounted) {
          cachedRoleNotifier.state = state.isWorkerAccount
              ? UserRole.worker
              : UserRole.client;
          // FIX (P2): restore idle + error (no separate isDeletingAccount: false needed)
          state = state.copyWith(
            status:       SettingsStatus.error,
            errorMessage: errorKey,
          );
        }
        return errorKey;
      }

      // Deletion confirmed — now safe to remove auth-related local data.
      // FIX [AUTO]: targeted removal instead of prefs.clear() so unrelated
      // preferences are not destroyed (theme, locale, notification settings…).
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(PrefKeys.accountRole);
        // Extend this list with any other auth-scoped pref keys as they are added.
        AppLogger.info('SettingsNotifier.deleteAccount: local auth prefs cleared');
      } catch (prefsError) {
        // Non-fatal — account is already deleted; local cleanup is best-effort.
        AppLogger.warning(
            'SettingsNotifier.deleteAccount: prefs cleanup failed — $prefsError');
      }

      return null;

    } catch (e) {
      AppLogger.error('SettingsNotifier.deleteAccount', e);

      if (mounted) {
        cachedRoleNotifier.state = state.isWorkerAccount
            ? UserRole.worker
            : UserRole.client;
        state = state.copyWith(
          status:       SettingsStatus.error,
          errorMessage: 'errors.delete_account_failed',
        );
      }
      return 'errors.delete_account_failed';
    }
  }

  Future<void> retry() async {
    if (mounted) state = const SettingsState();
    await _loadProfileData();
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final settingsProvider =
    StateNotifierProvider.autoDispose<SettingsNotifier, SettingsState>(
        (ref) => SettingsNotifier(ref));
