// lib/services/auth_service.dart
//
// App-wide authentication state notifier.
//
// Responsibilities:
//   - Expose the current Firebase user + computed auth properties.
//   - Notify the router and settings screen when auth state changes.
//   - Auto-provision the backend MongoDB profile after sign-in.
//   - Provide signOut() / deleteAccount() used by SettingsNotifier.
//
// This class is intentionally thin. The full phone auth flow (OTP, resend,
// cooldown, new-user check) lives in AuthController, which is screen-scoped
// and auto-disposed. AuthService is app-scoped and always alive.
//
// MIGRATION NOTE:
//   All email / social sign-in methods have been removed. Authentication is
//   exclusively via Firebase Phone Auth, handled by AuthController +
//   FirebaseAuthService.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/user_model.dart';
import 'api_service.dart';

class AuthService extends ChangeNotifier {
  static const Duration _authInitTimeout       = Duration(seconds: 10);
  static const Duration _backendProfileTimeout = Duration(seconds: 8);

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ApiService   _api;

  User?  _user;
  bool   _isInitialized = false;
  StreamSubscription<User?>? _authSub;

  // ── Getters ────────────────────────────────────────────────────────────────

  User? get user          => _user;
  bool  get isLoggedIn    => _user != null;
  bool  get isInitialized => _isInitialized;

  /// Phone auth users are always considered "verified" — there is no email
  /// verification step in this flow.
  bool  get emailVerified => true;

  // ── Constructor ────────────────────────────────────────────────────────────

  AuthService(this._api) {
    _initAuth();
  }

  void _initAuth() {
    _authSub = _auth.authStateChanges().listen(
      (User? user) {
        final prevUid = _user?.uid;
        _user          = user;
        _isInitialized = true;
        // Only notify on UID changes — prevents spurious rebuilds during
        // token refresh or app foreground transitions.
        if (prevUid != user?.uid) {
          notifyListeners();
          _log('Auth state: ${user?.uid ?? 'signed out'}');
        }
      },
      onError: (Object e) => _logError('authStateChanges', e),
    );
  }

  // ── Initialization ─────────────────────────────────────────────────────────

  /// Resolves when Firebase has emitted its first auth state event.
  /// Called by SplashController to gate navigation until auth is known.
  Future<void> waitForInitialization() async {
    if (_isInitialized) return;
    try {
      await _auth.authStateChanges().first.timeout(
        _authInitTimeout,
        onTimeout: () {
          _logWarning('Auth initialization timed out — proceeding as signed out');
          return null;
        },
      );
    } catch (e) {
      _logError('waitForInitialization', e);
    } finally {
      _isInitialized = true;
    }
  }

  // ── Backend profile auto-provisioning ──────────────────────────────────────

  /// Ensures a MongoDB profile exists for [firebaseUser].
  ///
  /// Called fire-and-forget from AuthController immediately after
  /// signInWithCredential succeeds. Never blocks navigation.
  ///
  /// If a profile already exists, this is a no-op. If not, a minimal
  /// 'client' profile is created from the phone number.
  Future<void> ensureBackendProfile(User firebaseUser) async {
    _ensureBackendProfile(firebaseUser).ignore();
  }

  Future<void> _ensureBackendProfile(User firebaseUser) async {
    try {
      final uid      = firebaseUser.uid;
      final existing = await _api.getUser(uid);
      if (existing != null) return;

      // No profile → create a minimal client profile from Firebase data.
      final name = firebaseUser.displayName?.trim().isNotEmpty == true
          ? firebaseUser.displayName!
          : _nameFromPhone(firebaseUser.phoneNumber);

      final user = UserModel(
        id:          uid,
        name:        name,
        email:       '',
        phoneNumber: firebaseUser.phoneNumber ?? '',
        lastUpdated: DateTime.now(),
        role:        'client',
      );
      await _api.createOrUpdateUser(user).timeout(_backendProfileTimeout);
      _log('Backend profile auto-created: $uid');
    } catch (e) {
      // Non-fatal — the user is authenticated in Firebase; the profile
      // will be created when the setup screen calls POST /users or /workers.
      _logWarning('_ensureBackendProfile non-fatal: $e');
    }
  }

  // ── Sign out ───────────────────────────────────────────────────────────────

  /// Signs the user out of Firebase.
  ///
  /// FCM token cleanup and worker status update are performed by
  /// SettingsNotifier.signOut() before calling this method.
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      _log('Signed out');
    } catch (e) {
      _logError('signOut', e);
    }
  }

  // ── Account deletion ───────────────────────────────────────────────────────

  /// Permanently deletes the Firebase Auth account.
  ///
  /// Returns a localization error key on failure, null on success.
  /// Requires recent sign-in — show re-auth UI if 'errors.requires_recent_login'.
  Future<String?> deleteAccount() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return 'errors.no_user';
    try {
      final uid = currentUser.uid;
      await currentUser.delete();
      _log('Account deleted: $uid');
      return null;
    } on FirebaseAuthException catch (e) {
      _logError('deleteAccount', e);
      if (e.code == 'requires-recent-login') return 'errors.requires_recent_login';
      return 'errors.delete_account_failed';
    } catch (e) {
      _logError('deleteAccount', e);
      return 'errors.delete_account_failed';
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Derives a display name from a phone number when no displayName is set.
  /// Ex: +213661234567 → "Utilisateur 4567"
  static String _nameFromPhone(String? phone) {
    if (phone == null || phone.length < 4) return 'Utilisateur';
    return 'Utilisateur ${phone.substring(phone.length - 4)}';
  }

  void _log(String msg)                 { if (kDebugMode) debugPrint('[AuthService] $msg'); }
  void _logWarning(String msg)          { if (kDebugMode) debugPrint('[AuthService] ⚠ $msg'); }
  void _logError(String method, Object e) { if (kDebugMode) debugPrint('[AuthService] ✗ $method: $e'); }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
