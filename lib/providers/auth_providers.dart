// lib/providers/auth_providers.dart
//
// App-level auth providers.
//
// MIGRATION NOTE:
//   - Removed appInitializedProvider (now in splash_controller, guards router)
//   - Kept firebaseAuthStreamProvider as the single source of truth for UID.
//   - LoginController / RegisterController removed — see AuthController.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_providers.dart';

// ── Auth redirect notifier ─────────────────────────────────────────────────
//
// Used by the router as part of its refreshListenable composite.
// Notified after sign-in and sign-out to trigger a redirect evaluation.

class AuthRedirectNotifier extends ChangeNotifier {
  void notifyAuthReady()  => notifyListeners();
  void notifySignedOut()  => notifyListeners();
}

final authRedirectNotifierProvider =
    Provider<AuthRedirectNotifier>((ref) => AuthRedirectNotifier());

// ── App initialized flag ───────────────────────────────────────────────────
//
// Set to true by SplashController when Firebase auth + onboarding state
// are both resolved. The router uses this to stay on /splash until ready.

final appInitializedProvider = StateProvider<bool>((ref) => false);

// ── Firebase auth stream ───────────────────────────────────────────────────
//
// Single source of truth for the authenticated Firebase user.
// Only emits on actual UID changes — never on isLoading flips.

final firebaseAuthStreamProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

// ── Computed auth providers ────────────────────────────────────────────────

/// Current Firebase user. Falls back to FirebaseAuth.instance.currentUser
/// during the loading frame to prevent a null-flash on first render.
final currentUserProvider = Provider<User?>((ref) {
  final stream = ref.watch(firebaseAuthStreamProvider);
  return stream.valueOrNull ?? FirebaseAuth.instance.currentUser;
});

final currentUserIdProvider = Provider<String?>((ref) {
  return ref.watch(currentUserProvider)?.uid;
});

/// True only while the auth stream has not yet emitted its first value.
/// This is NOT true during the phone auth flow — use AuthController.isLoading
/// for that.
final isAuthLoadingProvider = Provider<bool>((ref) {
  return ref.watch(firebaseAuthStreamProvider).isLoading;
});

final isLoggedInProvider = Provider<bool>((ref) {
  return ref.watch(currentUserProvider) != null;
});
