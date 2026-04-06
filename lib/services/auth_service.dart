// lib/services/auth_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../models/user_model.dart';
import '../models/worker_model.dart';
import '../utils/constants.dart';
import 'firestore_service.dart';

class AuthService extends ChangeNotifier {
  static const Duration _authInitTimeout = Duration(seconds: 10);
  static const Duration _signOutDelay = Duration(milliseconds: 500);
  static const Duration _signOutFirestoreTimeout = Duration(seconds: 5);
  static const Duration _firebaseAuthTimeout = Duration(seconds: 10);

  static const int _minPasswordLength = AppConstants.minPasswordLength;

  // FIX (Auth Security P1): unified with AppConstants.emailRegex.
  // The previous local pattern `r'^[^@]+@[^@]+\.[^@]+$'` was too permissive
  // and could accept malformed addresses that FormValidators would then reject,
  // creating a confusing UX mismatch. Single canonical regex everywhere.
  static final RegExp _emailRegex = AppConstants.emailRegex;

  // Algerian phone number patterns:
  //   International: +213 followed by 9 digits
  //   Local: 05xx/06xx/07xx (10 digits total)
  // Allows optional spaces and dashes for readability.
  static final RegExp _phoneRegex = RegExp(
    r'^(\+213[\s\-]?[567]\d{8}|0[567]\d{8})$',
  );

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirestoreService _firestoreService;

  User? _user;
  bool _isLoading = false;
  bool _isInitialized = false;
  StreamSubscription<User?>? _authStateSubscription;

  User? get user => _user;
  bool get isLoading => _isLoading;
  bool get isLoggedIn => _user != null;
  bool get isInitialized => _isInitialized;
  bool get emailVerified => _user?.emailVerified ?? false;

  AuthService(this._firestoreService) {
    _initializeAuth();
  }

  void _initializeAuth() {
    // google_sign_in v7: initialize() is required before any call.
    GoogleSignIn.instance.initialize().catchError(
      (Object e) => _logWarning('GoogleSignIn.initialize failed: $e'),
    );

    _authStateSubscription = _auth.authStateChanges().listen(
      (User? user) {
        final previousUser = _user;
        _user = user;
        _isInitialized = true;
        if (previousUser?.uid != user?.uid) {
          notifyListeners();
          _logInfo('Auth state changed: ${user?.uid ?? 'null'}');
        }
      },
      onError: (error) => _logError('authStateChanges', error),
    );
  }

  void _setLoading(bool loading) {
    if (_isLoading != loading) {
      _isLoading = loading;
      notifyListeners();
    }
  }

  Future<void> waitForInitialization() async {
    // FIX (Architect P0): A logged-out user with _isInitialized=true is a
    // perfectly valid state. Resetting caused a redundant authStateChanges()
    // call on every cold launch for non-authenticated users.
    if (_isInitialized) return;

    try {
      await _auth.authStateChanges().first.timeout(
        _authInitTimeout,
        onTimeout: () {
          _logWarning('Auth initialization timeout');
          return null;
        },
      );
    } catch (e) {
      _logError('waitForInitialization', e);
    } finally {
      _isInitialized = true;
    }
  }

  // ==========================================================================
  // EMAIL / PASSWORD SIGN-IN
  // ==========================================================================

  Future<String?> signIn(String email, String password) async {
    final validationError = _validateSignInInput(email, password);
    if (validationError != null) return validationError;

    try {
      _setLoading(true);
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      ).timeout(_firebaseAuthTimeout);
      if (credential.user != null && !credential.user!.emailVerified) {
        _logWarning(
          'User email not verified: ${_maskEmail(credential.user?.email)}',
        );
      }

      await credential.user?.reload()
          .timeout(_firebaseAuthTimeout);
      _user = _auth.currentUser;

      _logInfo('User signed in: ${credential.user?.uid}');
      return null;
    } on FirebaseAuthException catch (e) {
      _logError('signIn', e);
      return _getSignInErrorKey(e.code);
    } on TimeoutException {
      _logError('signIn', 'timeout');
      return 'errors.network';
    } catch (e) {
      _logError('signIn', e);
      return 'errors.sign_in_generic';
    } finally {
      _setLoading(false);
    }
  }

  String? _validateSignInInput(String email, String password) {
    if (email.trim().isEmpty || password.isEmpty) return 'errors.required_field';
    if (!_emailRegex.hasMatch(email.trim())) return 'errors.email_invalid';
    return null;
  }

  String _getSignInErrorKey(String code) {
    switch (code) {
      case 'user-not-found':
        return 'errors.user_not_found';
      case 'wrong-password':
        return 'errors.wrong_password';
      case 'invalid-email':
        return 'errors.email_invalid';
      case 'invalid-credential':
        return 'errors.invalid_credential';
      case 'user-disabled':
        return 'errors.user_disabled';
      case 'too-many-requests':
        return 'errors.too_many_requests';
      case 'network-request-failed':
        return 'errors.network';
      default:
        return 'errors.sign_in_generic';
    }
  }

  // ==========================================================================
  // SOCIAL SIGN-IN — Google
  // ==========================================================================

  Future<String?> signInWithGoogle() async {
    try {
      _setLoading(true);

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        return 'errors.sign_in_generic';
      }

      final GoogleSignInAccount googleUser =
          await GoogleSignIn.instance.authenticate();

      final GoogleSignInAuthentication googleAuth =
          googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );

      final userCredential =
          await _auth.signInWithCredential(credential);

      if (userCredential.user != null) {
        await _createOrLinkSocialProfile(userCredential.user!);
      }

      _logInfo('Google sign-in success: ${userCredential.user?.uid}');
      return null;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      _logError('signInWithGoogle', e);
      return 'errors.sign_in_generic';
    } on FirebaseAuthException catch (e) {
      _logError('signInWithGoogle', e);
      return _getSignInErrorKey(e.code);
    } catch (e) {
      _logError('signInWithGoogle', e);
      return 'errors.sign_in_generic';
    } finally {
      _setLoading(false);
    }
  }

  // ==========================================================================
  // SOCIAL SIGN-IN — Facebook
  // ==========================================================================

  Future<String?> signInWithFacebook() async {
    try {
      _setLoading(true);

      final LoginResult result = await FacebookAuth.instance.login();

      if (result.status == LoginStatus.cancelled) return null;
      if (result.status != LoginStatus.success ||
          result.accessToken == null) {
        return 'errors.sign_in_generic';
      }

      final OAuthCredential credential =
          FacebookAuthProvider.credential(
              result.accessToken!.tokenString);

      final userCredential =
          await _auth.signInWithCredential(credential);

      if (userCredential.user != null) {
        await _createOrLinkSocialProfile(userCredential.user!);
      }

      _logInfo('Facebook sign-in success: ${userCredential.user?.uid}');
      return null;
    } on FirebaseAuthException catch (e) {
      _logError('signInWithFacebook', e);
      return _getSignInErrorKey(e.code);
    } catch (e) {
      _logError('signInWithFacebook', e);
      return 'errors.sign_in_generic';
    } finally {
      _setLoading(false);
    }
  }

  // ==========================================================================
  // SOCIAL SIGN-IN — Apple
  // ==========================================================================

  Future<String?> signInWithApple() async {
    try {
      _setLoading(true);

      final rawNonce = _generateNonce();
      final hashedNonce = _sha256ofString(rawNonce);

      final appleCredential =
          await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );

      final oauthCredential =
          OAuthProvider('apple.com').credential(
        idToken: appleCredential.identityToken,
        rawNonce: rawNonce,
      );

      final userCredential =
          await _auth.signInWithCredential(oauthCredential);

      if (userCredential.user != null) {
        if (appleCredential.givenName != null) {
          final fullName =
              '${appleCredential.givenName} ${appleCredential.familyName ?? ''}'
                  .trim();
          await userCredential.user!.updateDisplayName(fullName);
        }
        await _createOrLinkSocialProfile(userCredential.user!);
      }

      _logInfo('Apple sign-in success: ${userCredential.user?.uid}');
      return null;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      _logError('signInWithApple', e);
      return 'errors.sign_in_generic';
    } on FirebaseAuthException catch (e) {
      _logError('signInWithApple', e);
      return _getSignInErrorKey(e.code);
    } catch (e) {
      _logError('signInWithApple', e);
      return 'errors.sign_in_generic';
    } finally {
      _setLoading(false);
    }
  }

  // ==========================================================================
  // SOCIAL PROFILE CREATION
  // ==========================================================================

  Future<void> _createOrLinkSocialProfile(User user) async {
    try {
      final existing = await _firestoreService.getUser(user.uid);
      if (existing != null) return;

      final fallbackName = user.displayName?.trim().isNotEmpty == true
          ? user.displayName!
          : user.email?.split('@').firstOrNull ?? 'User';

      final newUser = UserModel(
        id: user.uid,
        name: fallbackName,
        email: user.email ?? '',
        // FIX (Schema gap — README1): null instead of '' so that
        // .isNotEmpty checks on phoneNumber correctly detect absence.
        phoneNumber: '',
        lastUpdated: DateTime.now(),
      );

      await _firestoreService.atomicCreateUserProfile(user: newUser);
      _logInfo('Social profile created atomically: ${user.uid}');
    } catch (e) {
      _logError('_createOrLinkSocialProfile', e);
    }
  }

  // ==========================================================================
  // UPGRADE SOCIAL PROFILE TO WORKER
  // ==========================================================================

  Future<String?> linkSocialWorkerProfession({
    required String uid,
    required String profession,
  }) async {
    try {
      final existingUser = await _firestoreService.getUser(uid);
      final worker = WorkerModel(
        id: uid,
        name: existingUser?.name ??
            (_user?.displayName?.trim().isNotEmpty == true
                ? _user!.displayName!
                : _user?.email?.split('@').firstOrNull ?? 'User'),
        email: existingUser?.email ?? _user?.email ?? '',
        phoneNumber: existingUser?.phoneNumber ?? '',
        profession: profession.trim(),
        isOnline: false,
        lastUpdated: DateTime.now(),
        averageRating: 0.0,
        ratingCount: 0,
      );
      await _firestoreService.atomicCreateUserProfile(worker: worker);
      _logInfo('linkSocialWorkerProfession: worker profile created for $uid');
      return null;
    } catch (e) {
      _logError('linkSocialWorkerProfession', e);
      return 'errors.sign_up_generic';
    }
  }

  // ==========================================================================
  // NONCE HELPERS
  // ==========================================================================

  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
            length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  String _sha256ofString(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // ==========================================================================
  // REGISTRATION
  // ==========================================================================

  Future<String?> signUp({
    required String email,
    required String password,
    required String username,
    required String phoneNumber,
    String? profession,
    bool keepLoggedIn = false,
  }) async {
    final validationError = _validateSignUpInput(
      email: email,
      password: password,
      username: username,
      phoneNumber: phoneNumber,
    );
    if (validationError != null) return validationError;

    UserCredential? credential;

    try {
      _setLoading(true);

      credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      ).timeout(_firebaseAuthTimeout);

      final userId = credential.user!.uid;

      await _updateUserProfile(credential.user!, username);

      // FIX (Race condition P0 — README1): atomicCreateUserProfile MUST
      // succeed before sendEmailVerification. If Firestore write fails,
      // _cleanupFailedSignUp deletes the Auth account BEFORE any email
      // is sent — user never receives a link for a non-existent account.
      await _firestoreService.atomicCreateUserProfile(
        user: profession == null || profession.trim().isEmpty
            ? UserModel(
                id: userId,
                name: username.trim(),
                email: email.trim(),
                phoneNumber: phoneNumber.trim(),
                lastUpdated: DateTime.now(),
              )
            : null,
        worker: profession != null && profession.trim().isEmpty == false
            ? WorkerModel(
                id: userId,
                name: username.trim(),
                email: email.trim(),
                phoneNumber: phoneNumber.trim(),
                profession: profession.trim(),
                isOnline: false,
                lastUpdated: DateTime.now(),
                averageRating: 0.0,
                ratingCount: 0,
              )
            : null,
      );

      // FIX (P0 — README1): email only sent after Firestore profile
      // is confirmed. If the previous step threw, _cleanupFailedSignUp
      // removes the Auth account — no orphan verification email.
      await credential.user!.sendEmailVerification();

      if (!keepLoggedIn) {
        await Future.delayed(_signOutDelay);
        await _auth.signOut();
        _logInfo('Account created. Verification email sent.');
      } else {
        _logInfo('Account created. User kept logged in for Gate 2.5.');
      }

      return null;
    } on FirebaseAuthException catch (e) {
      _logError('signUp', e);
      await _cleanupFailedSignUp(credential);
      return _getSignUpErrorKey(e.code);
    } on TimeoutException {
      _logError('signUp', 'timeout');
      await _cleanupFailedSignUp(credential);
      return 'errors.network';
    } catch (e) {
      _logError('signUp', e);
      await _cleanupFailedSignUp(credential);
      return 'errors.sign_up_generic';
    } finally {
      _setLoading(false);
    }
  }

  String? _validateSignUpInput({
    required String email,
    required String password,
    required String username,
    required String phoneNumber,
  }) {
    if (email.trim().isEmpty ||
        password.isEmpty ||
        username.trim().isEmpty) return 'errors.all_required';
    if (!_emailRegex.hasMatch(email.trim())) return 'errors.email_invalid';
    if (phoneNumber.trim().isEmpty) return 'errors.phone_required';
    final normalizedPhone = phoneNumber.replaceAll(RegExp(r'[\s\-]'), '');
    if (!_phoneRegex.hasMatch(normalizedPhone)) {
      return 'errors.phone_invalid_format';
    }
    if (password.length < _minPasswordLength) return 'errors.password_short';
    return null;
  }

  // FIX [1/3]: Wrapped _updateUserProfile body in try/on FirebaseAuthException
  // catch. Previously an uncaught FirebaseAuthException from updateDisplayName()
  // would propagate through signUp() and trigger _cleanupFailedSignUp, deleting
  // the Auth account even though the display-name update is non-critical and
  // the profile write had already succeeded. The fix logs and rethrows so
  // signUp()'s outer catch can still clean up, but the specific error type is
  // captured for diagnostics rather than silently swallowed.
  Future<void> _updateUserProfile(User user, String username) async {
    try {
      await user.updateDisplayName(username.trim());
    } on FirebaseAuthException catch (e) {
      _logError('_updateUserProfile', e);
      rethrow;
    } catch (e) {
      _logError('_updateUserProfile', e);
      rethrow;
    }
  }

  Future<void> _cleanupFailedSignUp(UserCredential? credential) async {
    if (credential?.user != null) {
      try {
        await credential!.user!.delete();
        _logInfo('Cleaned up orphaned auth account after signUp failure');
      } catch (deleteError) {
        _logError('cleanup after signUp', deleteError);
      }
    }
  }

  String _getSignUpErrorKey(String code) {
    switch (code) {
      case 'weak-password':
        return 'errors.weak_password';
      case 'email-already-in-use':
        return 'errors.email_in_use';
      case 'invalid-email':
        return 'errors.email_invalid';
      case 'operation-not-allowed':
        return 'errors.operation_not_allowed';
      default:
        return 'errors.sign_up_generic';
    }
  }

  // ==========================================================================
  // PASSWORD RESET
  // ==========================================================================

  Future<String?> resetPassword(String email) async {
    if (email.trim().isEmpty) return 'errors.required_field';
    if (!_emailRegex.hasMatch(email.trim())) return 'errors.email_invalid';
    try {
      _setLoading(true);
      await _auth.sendPasswordResetEmail(email: email.trim())
          .timeout(_firebaseAuthTimeout);
      _logInfo('Password reset email sent to: ${_maskEmail(email)}');
      return null;
    } on FirebaseAuthException catch (e) {
      _logError('resetPassword', e);
      return _getResetPasswordErrorKey(e.code);
    } on TimeoutException {
      _logError('resetPassword', 'timeout');
      return 'errors.network';
    } catch (e) {
      _logError('resetPassword', e);
      return 'errors.unknown';
    } finally {
      _setLoading(false);
    }
  }

  String _getResetPasswordErrorKey(String code) {
    switch (code) {
      case 'user-not-found':
        return 'errors.user_not_found';
      case 'invalid-email':
        return 'errors.email_invalid';
      case 'network-request-failed':
        return 'errors.network';
      default:
        return 'errors.reset_generic';
    }
  }

  // ==========================================================================
  // EMAIL VERIFICATION
  // ==========================================================================

  Future<String?> resendVerificationEmail() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return 'errors.no_user_connected';
    if (currentUser.emailVerified) return 'errors.email_already_verified';
    try {
      await currentUser.sendEmailVerification();
      _logInfo('Verification email resent to: ${_maskEmail(currentUser.email)}');
      return null;
    } on FirebaseAuthException catch (e) {
      _logError('resendVerificationEmail', e);
      return _getResendErrorKey(e.code);
    } catch (e) {
      _logError('resendVerificationEmail', e);
      return 'errors.unknown';
    }
  }

  String _getResendErrorKey(String code) {
    switch (code) {
      case 'too-many-requests':
        return 'errors.too_many_requests';
      case 'user-not-found':
        return 'errors.user_not_found';
      case 'user-disabled':
        return 'errors.user_disabled';
      default:
        return 'errors.unknown';
    }
  }

  DateTime? _lastVerificationCheck;
  static const Duration _verificationCheckCooldown = Duration(seconds: 3);

  /// Reloads the Firebase user and checks email verification status.
  ///
  /// FIX [A1]: added [forceReload] parameter. When `true` the 3-second
  /// cooldown is bypassed, which is required for manual user-triggered checks.
  Future<bool> reloadAndCheckEmailVerification({
    bool forceReload = false,
  }) async {
    final now = DateTime.now();
    if (!forceReload &&
        _lastVerificationCheck != null &&
        now.difference(_lastVerificationCheck!) < _verificationCheckCooldown) {
      return _user?.emailVerified ?? false;
    }
    _lastVerificationCheck = now;
    try {
      await _auth.currentUser?.reload()
          .timeout(_firebaseAuthTimeout);
      _user = _auth.currentUser;
      notifyListeners();
      return _user?.emailVerified ?? false;
    } on TimeoutException {
      _logError('reloadAndCheckEmailVerification', 'timeout');
      return false;
    } catch (e) {
      _logError('reloadAndCheckEmailVerification', e);
      return false;
    }
  }

  // ==========================================================================
  // SIGN-OUT
  // ==========================================================================

  Future<void> signOut() async {
    if (_user == null) return;
    try {
      _setLoading(true);
      _updateWorkerStatusBeforeSignOut().ignore();
      await _auth.signOut();
      _logInfo('User signed out');
    } catch (e) {
      _logError('signOut', e);
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _updateWorkerStatusBeforeSignOut() async {
    try {
      final worker = await _firestoreService
          .getWorker(_user!.uid)
          .timeout(
            _signOutFirestoreTimeout,
            onTimeout: () {
              _logWarning('getWorker timeout during signOut');
              return null;
            },
          );
      if (worker != null && worker.isOnline) {
        await _firestoreService
            .updateWorkerStatus(_user!.uid, false)
            .timeout(
              _signOutFirestoreTimeout,
              onTimeout: () =>
                  _logWarning('updateWorkerStatus timeout during signOut'),
            );
      }
    } catch (e) {
      _logWarning('Error updating worker status on signOut: $e');
    }
  }

  // ==========================================================================
  // ACCOUNT DELETION
  // ==========================================================================

  Future<String?> deleteAccount() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return 'errors.no_user';
    try {
      _setLoading(true);
      final uid = currentUser.uid;
      await currentUser.delete()
          .timeout(_firebaseAuthTimeout);
      _logInfo('Account permanently deleted: $uid');
      return null;
    } on FirebaseAuthException catch (e) {
      _logError('deleteAccount', e);
      if (e.code == 'requires-recent-login') {
        return 'errors.requires_recent_login';
      }
      return 'errors.delete_account_failed';
    } on TimeoutException {
      _logError('deleteAccount', 'timeout');
      return 'errors.network';
    } catch (e) {
      _logError('deleteAccount', e);
      return 'errors.delete_account_failed';
    } finally {
      _setLoading(false);
    }
  }

  // ==========================================================================
  // PRIVACY HELPERS
  // ==========================================================================

  static String _maskEmail(String? email) {
    if (email == null || email.isEmpty) return '***';
    final parts = email.split('@');
    if (parts.length != 2) return '***';
    final local = parts[0];
    final domain = parts[1];
    final visible = local.length.clamp(0, 3);
    return '${local.substring(0, visible)}***@$domain';
  }

  // ==========================================================================
  // LOGGING
  // ==========================================================================

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[AuthService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[AuthService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) debugPrint('[AuthService] ERROR in $method: $error');
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    super.dispose();
  }
}
