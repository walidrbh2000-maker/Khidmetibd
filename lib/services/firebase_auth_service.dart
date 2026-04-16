// lib/services/firebase_auth_service.dart
//
// Pure wrapper around FirebaseAuth phone verification.
// Contains zero business logic — all decisions are in AuthController.
//
// Design notes:
// - No state, no ChangeNotifier. Stateless service injected via Riverpod.
// - Error codes are mapped here to localization keys so controllers
//   never need to import firebase_auth for error handling.
// - isPnvSupported() is a future-proofing hook: when Algerian carriers
//   join Firebase Phone Number Verification (PNV), this will return true
//   and the controller can route to the frictionless flow instead of SMS OTP.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────

class FirebaseAuthService {
  static const Duration _verificationTimeout = Duration(seconds: 60);

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ── Getters ────────────────────────────────────────────────────────────────

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ── Phone verification ─────────────────────────────────────────────────────

  /// Triggers Firebase SMS OTP flow.
  ///
  /// All four callbacks are required — the controller wires them to state
  /// transitions. Never call this directly from the UI.
  ///
  /// [forceResendingToken] must be passed on resend requests to avoid
  /// re-billing the same SMS session.
  Future<void> sendVerificationCode({
    required String phone,
    required void Function(PhoneAuthCredential)            onVerificationCompleted,
    required void Function(FirebaseAuthException)          onVerificationFailed,
    required void Function(String verificationId, int?)    onCodeSent,
    required void Function(String verificationId)          onCodeAutoRetrievalTimeout,
    int? forceResendingToken,
  }) async {
    _log('sendVerificationCode → $phone');
    await _auth.verifyPhoneNumber(
      phoneNumber:          phone,
      timeout:              _verificationTimeout,
      forceResendingToken:  forceResendingToken,
      verificationCompleted: onVerificationCompleted,
      verificationFailed:    onVerificationFailed,
      codeSent:              onCodeSent,
      codeAutoRetrievalTimeout: onCodeAutoRetrievalTimeout,
    );
  }

  /// Signs in with a [PhoneAuthCredential] (from instant verification or OTP).
  Future<UserCredential> signInWithCredential(PhoneAuthCredential credential) {
    return _auth.signInWithCredential(credential);
  }

  /// Builds a PhoneAuthCredential from the stored verificationId + user code.
  PhoneAuthCredential buildCredential({
    required String verificationId,
    required String smsCode,
  }) {
    return PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode:        smsCode,
    );
  }

  // ── Session management ─────────────────────────────────────────────────────

  Future<void> signOut() => _auth.signOut();

  /// Permanently deletes the Firebase account.
  /// Returns a localization error key on failure, null on success.
  Future<String?> deleteAccount() async {
    try {
      await _auth.currentUser?.delete();
      return null;
    } on FirebaseAuthException catch (e) {
      _log('deleteAccount error: ${e.code}');
      if (e.code == 'requires-recent-login') return 'errors.requires_recent_login';
      return 'errors.delete_account_failed';
    } catch (_) {
      return 'errors.delete_account_failed';
    }
  }

  // ── Feature detection ──────────────────────────────────────────────────────

  /// Returns true when Firebase PNV is available for the current SIM.
  ///
  /// As of April 2026, Algerian carriers (Djezzy, Mobilis, Ooredoo) do NOT
  /// participate in Firebase PNV. This always returns false until they join.
  /// Monitor: firebase.google.com/docs/phone-number-verification
  Future<bool> isPnvSupported() async => false;

  // ── Error mapping ──────────────────────────────────────────────────────────

  /// Maps a FirebaseAuthException code to a localization key.
  static String mapFirebaseError(String code) {
    switch (code) {
      case 'invalid-verification-code': return 'errors.otp_invalid';
      case 'session-expired':           return 'errors.otp_expired';
      case 'quota-exceeded':            return 'errors.quota_exceeded';
      case 'too-many-requests':         return 'errors.too_many_requests';
      case 'network-request-failed':    return 'errors.network';
      case 'invalid-phone-number':      return 'errors.phone_invalid_format';
      case 'missing-phone-number':      return 'errors.phone_invalid_format';
      default:                          return 'errors.auth_generic';
    }
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[FirebaseAuthService] $msg');
  }
}
