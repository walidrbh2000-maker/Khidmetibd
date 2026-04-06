// lib/providers/user_role_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core_providers.dart';

// ============================================================================
// USER ROLE ENUM
// ============================================================================

/// User role enum (renamed from UserType to avoid conflict with constants.dart)
enum UserRole {
  client,
  worker,
  unknown,
}

// ============================================================================
// ASYNC ROLE PROVIDER (Firestore lookup — use sparingly)
// ============================================================================

/// Provider that determines if current user is a worker or client.
/// Makes a live Firestore call — prefer cachedUserRoleProvider for sync reads.
///
/// FIX (P4 — W3): replaced ref.watch(authServiceProvider) with
/// ref.watch(currentUserProvider). authServiceProvider is a
/// ChangeNotifierProvider that fires notifyListeners() on every isLoading
/// change (e.g. during sign-in), which previously caused this provider to
/// make a new Firestore call on every such notification.
/// currentUserProvider only changes when the UID actually changes, so
/// Firestore is only re-queried on real auth state transitions.
final currentUserRoleProvider = FutureProvider.autoDispose<UserRole>((ref) async {
  // FIX (P4): watch the UID-scoped provider instead of the full AuthService
  // ChangeNotifier to avoid spurious Firestore re-fetches on isLoading changes.
  final user = ref.watch(currentUserProvider);
  final firestoreService = ref.watch(firestoreServiceProvider);

  if (user == null) return UserRole.unknown;

  try {
    final worker = await firestoreService.getWorker(user.uid);
    if (worker != null) return UserRole.worker;

    final client = await firestoreService.getUser(user.uid);
    if (client != null) return UserRole.client;

    return UserRole.unknown;
  } catch (e) {
    return UserRole.client;
  }
});

// ============================================================================
// ACCOUNT TYPE PROVIDER  (cachedUserRoleProvider)
// ============================================================================
//
// PURPOSE: Represents the Firebase account type — is this user registered
// as a worker in Firestore?
//
// WRITTEN BY:
//   - SplashController._resolveAndCacheRole()  (cold launch)
//   - LoginController._resolveAndPersistRole() (email/social login)
//   - RegisterController._cacheRole()          (registration)
//
// FIX (Cross-Screen Flow P1 — shared state conflict guard):
// cachedUserRoleProvider can be written concurrently by LoginController and
// RegisterController in edge cases where a partial OAuth session exists
// (e.g. user starts social registration, back-navigates, then logs in).
// The guard below prevents an already-resolved role from being overwritten
// by a stale unknown write. Controllers should check this before writing:
//
//   final current = ref.read(cachedUserRoleProvider);
//   if (current != UserRole.unknown) return; // already resolved, skip
//
// This contract is documented here and enforced at write sites.
// The StateProvider itself cannot enforce it — callers must respect the guard.

/// Synchronous in-memory cache of the user's Firebase account type.
///
/// WRITE GUARD CONTRACT (callers must enforce):
/// Only write if the current value is UserRole.unknown, OR if you are
/// explicitly replacing a known role (e.g. worker upgrade).
/// Never overwrite a non-unknown role with unknown.
final cachedUserRoleProvider = StateProvider<UserRole>((ref) => UserRole.unknown);

// ============================================================================
// WRITE GUARD HELPER — use this in controllers instead of direct state write
// ============================================================================

/// Writes [role] to [cachedUserRoleProvider] only if the current value
/// is [UserRole.unknown] OR [force] is true.
///
/// Usage in controllers:
///   setCachedUserRole(ref, UserRole.worker);               // guarded
///   setCachedUserRole(ref, UserRole.worker, force: true);  // forced (upgrade)
void setCachedUserRole(Ref ref, UserRole role, {bool force = false}) {
  final current = ref.read(cachedUserRoleProvider);
  if (force || current == UserRole.unknown) {
    ref.read(cachedUserRoleProvider.notifier).state = role;
  }
  // If current is already a known role and force is false, the write is
  // silently skipped — the first writer wins, preventing race conditions.
}
