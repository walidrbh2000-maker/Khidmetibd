// lib/providers/auth_providers.dart
//
// TASK 1 FIX — AuthService ChangeNotifierProvider migration.
//
// WHAT CHANGED:
//   • firebaseAuthStreamProvider (new): StreamProvider<User?> driven directly
//     by FirebaseAuth.instance.authStateChanges(). This is the single source of
//     truth for the current user — it has no isLoading side effects.
//   • currentUserProvider: now watches firebaseAuthStreamProvider instead of
//     authServiceProvider (ChangeNotifier). Falls back to
//     FirebaseAuth.instance.currentUser synchronously during the loading frame
//     so there is no null-flash before the stream emits.
//   • isAuthLoadingProvider: watches the stream's loading state (true only
//     before the first auth emission, not during signIn/signUp operations).
//   • isLoggedInProvider, currentUserIdProvider: unchanged in API, now derived
//     from the corrected currentUserProvider.
//
// WHY:
//   authServiceProvider (ChangeNotifierProvider) called notifyListeners() on
//   every isLoading flip inside signIn/signUp flows, which caused
//   currentUserRoleProvider and any ref.watch(authServiceProvider) consumer to
//   rebuild and re-fetch Firestore on every state transition — not just on UID
//   changes. The stream approach only fires on actual auth state changes.
//
// DEPENDENCY NOTE (unchanged):
//   auth_providers → core_providers (import)
//   core_providers → auth_providers (re-export)
//   This is a one-directional import chain — NOT circular.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_providers.dart';

// ============================================================================
// APP INITIALIZATION PROVIDER
// ============================================================================

final appInitializedProvider = StateProvider<bool>((ref) => false);

// ============================================================================
// AUTH REDIRECT NOTIFIER
// ============================================================================

class AuthRedirectNotifier extends ChangeNotifier {
  void notifyAuthReady() => notifyListeners();
  void notifySignedOut() => notifyListeners();
}

final authRedirectNotifierProvider =
    Provider<AuthRedirectNotifier>((ref) => AuthRedirectNotifier());

// ============================================================================
// FIREBASE AUTH STREAM — single source of truth for current user
// ============================================================================
//
// FIX (Task 1 — ChangeNotifierProvider migration):
// Driving currentUserProvider from FirebaseAuth.instance.authStateChanges()
// means reactive auth state is now completely decoupled from AuthService's
// internal isLoading / isLoading-flip notification cycle. The stream only
// emits on UID-level auth changes (sign-in, sign-out, token refresh) — never
// on load-state changes that are internal to AuthService operations.

final firebaseAuthStreamProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

// ============================================================================
// COMPUTED AUTH PROVIDERS
// ============================================================================

/// The currently authenticated Firebase user.
///
/// FIX (Task 1): Previously `ref.watch(authServiceProvider).user`, which
/// subscribed to the ChangeNotifier and rebuilt on every `notifyListeners()`
/// call (including isLoading flips during signIn). Now driven by
/// [firebaseAuthStreamProvider] which only emits on actual UID changes.
///
/// Falls back to `FirebaseAuth.instance.currentUser` synchronously during the
/// short loading frame before the stream emits its first value, preventing a
/// null-flash in screens that display `user.email`.
final currentUserProvider = Provider<User?>((ref) {
  final streamState = ref.watch(firebaseAuthStreamProvider);
  // During AsyncLoading, use the synchronous currentUser so there is no
  // null-flash before the stream emits.
  return streamState.valueOrNull ?? FirebaseAuth.instance.currentUser;
});

final currentUserIdProvider = Provider<String?>((ref) {
  return ref.watch(currentUserProvider)?.uid;
});

/// True only while the auth stream has not yet emitted its first value
/// (i.e. app startup, before Firebase resolves the persisted credential).
/// This is NOT true during signIn/signUp operations — use controller state for that.
final isAuthLoadingProvider = Provider<bool>((ref) {
  return ref.watch(firebaseAuthStreamProvider).isLoading;
});

final isLoggedInProvider = Provider<bool>((ref) {
  return ref.watch(currentUserProvider) != null;
});
