// lib/providers/settings_provider.dart
//
// MIGRATION NOTE:
//   - _loadProfileData() is unchanged (already uses unified getUser(uid) → isWorker).
//   - signOut() now explicitly calls updateWorkerOnlineStatus(false) when the
//     user is a worker, since auth_service.signOut() no longer does it.
//   - Removed reference to email-auth methods.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_providers.dart';
import 'core_providers.dart';
import 'user_role_provider.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';

// ── State ──────────────────────────────────────────────────────────────────

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

  bool get isSigningOut      => status == SettingsStatus.signingOut;
  bool get isDeletingAccount => status == SettingsStatus.deletingAccount;

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

// ── Notifier ───────────────────────────────────────────────────────────────

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

      // Single request — unified collection, `role` field discriminates client/worker.
      final userDoc = await firestoreService.getUser(uid);

      if (!mounted) return;

      if (userDoc == null) {
        final firebaseUser = authService.user;
        state = state.copyWith(
          status:          SettingsStatus.idle,
          userName:        firebaseUser?.displayName ?? '',
          activeRole:      UserRole.client,
          isWorkerAccount: false,
        );
        AppLogger.warning('Settings: userDoc null for uid=$uid — fallback to Firebase');
        return;
      }

      if (userDoc.isWorker) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(PrefKeys.accountRole, UserType.worker);

        if (!mounted) return;
        state = state.copyWith(
          status:              SettingsStatus.idle,
          userName:            userDoc.name,
          professionLabel:     userDoc.profession,
          profileImageUrl:     userDoc.profileImageUrl,
          activeRole:          UserRole.worker,
          isWorkerAccount:     true,
          workerAverageRating: userDoc.averageRating,
          workerRatingCount:   userDoc.ratingCount,
        );
      } else {
        if (!mounted) return;
        state = state.copyWith(
          status:          SettingsStatus.idle,
          userName:        userDoc.name,
          profileImageUrl: userDoc.profileImageUrl,
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

  Future<void> signOut() async {
    if (!mounted) return;
    if (state.isSigningOut) return;

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
        // Clear FCM token
        try {
          await firestoreService.updateUserFcmToken(uid, '');
          if (state.isWorkerAccount) {
            await firestoreService.updateWorkerFcmToken(uid, '');
            // Set worker offline — auth_service no longer does this.
            await firestoreService.updateWorkerOnlineStatus(uid, false);
          }
        } catch (fcmError) {
          AppLogger.warning('FCM/status cleanup failed: $fcmError');
        }
      }

      await authService.signOut();

      // Clear role pref AFTER sign-out succeeds.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(PrefKeys.accountRole);
      } catch (e) {
        AppLogger.warning('signOut: prefs.remove failed — $e');
      }
    } catch (e) {
      AppLogger.error('SettingsNotifier.signOut', e);
      if (mounted) {
        cachedRoleNotifier.state = state.isWorkerAccount ? UserRole.worker : UserRole.client;
        state = state.copyWith(
          status:       SettingsStatus.error,
          errorMessage: 'errors.signout_failed',
        );
      }
    }
  }

  Future<String?> deleteAccount() async {
    if (!mounted) return null;
    if (state.isDeletingAccount) return null;

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

      if (uid != null) {
        try {
          await firestoreService.updateUserFcmToken(uid, '');
          if (state.isWorkerAccount) {
            await firestoreService.updateWorkerFcmToken(uid, '');
          }
        } catch (fcmError) {
          AppLogger.warning('deleteAccount: FCM cleanup failed — $fcmError');
        }
      }

      final errorKey = await authService.deleteAccount();
      if (errorKey != null) {
        if (mounted) {
          cachedRoleNotifier.state = state.isWorkerAccount ? UserRole.worker : UserRole.client;
          state = state.copyWith(
            status:       SettingsStatus.error,
            errorMessage: errorKey,
          );
        }
        return errorKey;
      }

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(PrefKeys.accountRole);
      } catch (e) {
        AppLogger.warning('deleteAccount: prefs cleanup failed — $e');
      }

      return null;
    } catch (e) {
      AppLogger.error('SettingsNotifier.deleteAccount', e);
      if (mounted) {
        cachedRoleNotifier.state = state.isWorkerAccount ? UserRole.worker : UserRole.client;
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

// ── Provider ───────────────────────────────────────────────────────────────

final settingsProvider =
    StateNotifierProvider.autoDispose<SettingsNotifier, SettingsState>(
        (ref) => SettingsNotifier(ref));
