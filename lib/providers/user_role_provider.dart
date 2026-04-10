// lib/providers/user_role_provider.dart
//
// OPTIMISATION — REQUÊTE UNIQUE
// ────────────────────────────────────────────────────────────────────────────
// Avant la migration, currentUserRoleProvider effectuait jusqu'à DEUX
// requêtes pour déterminer le rôle d'un utilisateur :
//   1. GET /workers/:uid  → si 404, l'utilisateur n'est pas worker
//   2. GET /users/:uid    → pour confirmer qu'il est client
//
// Après la fusion de la collection, GET /users/:uid retourne le document
// unifié avec le champ `role`. Une seule requête suffit. L'économie est
// significative : moins de latence, moins de tokens Firebase, moins de
// charge serveur.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// UserRole — enum applicatif (avec unknown pour l'état de chargement)
// ─────────────────────────────────────────────────────────────────────────────
// distinct de la valeur `role` dans UserModel (String 'client'|'worker')
// pour permettre la notion d'état indéterminé nécessaire à l'UI.

enum UserRole {
  client,
  worker,
  /// État transitoire : non encore résolu (démarrage) ou non authentifié.
  unknown,
}

// ─────────────────────────────────────────────────────────────────────────────
// currentUserRoleProvider — lookup Firestore en direct
// ─────────────────────────────────────────────────────────────────────────────
// Usage : uniquement quand le cache (cachedUserRoleProvider) n'est pas encore
// résolu. Préférer cachedUserRoleProvider pour les lectures synchrones.
//
// OPTIMISATION (post-migration) :
//   Une seule requête GET /users/:uid suffit — le champ `role` du document
//   retourné discrimine client vs worker. Avant la fusion, deux requêtes
//   pouvaient être nécessaires (getWorker + getUser).
//
// FIX (P4 — W3) : ref.watch(currentUserProvider) au lieu de authServiceProvider
// évite les rebuilds sur isLoading. Seul un vrai changement d'UID déclenche
// une nouvelle requête Firestore.
final currentUserRoleProvider = FutureProvider.autoDispose<UserRole>((ref) async {
  final user             = ref.watch(currentUserProvider);
  final firestoreService = ref.watch(firestoreServiceProvider);

  if (user == null) return UserRole.unknown;

  try {
    // OPTIMISATION : une seule requête — le champ `role` est dans le document.
    final userDoc = await firestoreService.getUser(user.uid);
    if (userDoc == null) return UserRole.unknown;
    return userDoc.isWorker ? UserRole.worker : UserRole.client;
  } catch (_) {
    // Dégradation gracieuse : traiter comme client en cas d'erreur réseau.
    return UserRole.client;
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// cachedUserRoleProvider — cache en mémoire du rôle résolu
// ─────────────────────────────────────────────────────────────────────────────
// Écrit par : SplashController, LoginController, RegisterController
// Lu par    : router (redirect guard), SettingsNotifier, WorkerHomeController
//
// CONTRAT D'ÉCRITURE — OBLIGATOIRE pour tous les writers :
//   N'écrire que si la valeur actuelle est `unknown`, OU si `force: true`.
//   Ne jamais écraser un rôle résolu par `unknown` — cela provoque un
//   redirect loop dans le router.
//   → Utiliser setCachedUserRole(ref, role) et non .state = role directement.
final cachedUserRoleProvider =
    StateProvider<UserRole>((ref) => UserRole.unknown);

// ─────────────────────────────────────────────────────────────────────────────
// setCachedUserRole — helper thread-safe pour écrire dans le cache
// ─────────────────────────────────────────────────────────────────────────────
// [force: false] → écriture seulement si le rôle actuel est unknown
// [force: true]  → écriture inconditionnelle (upgrade client→worker, etc.)
//
// Le flag force est nécessaire pour les cas de re-login ou d'upgrade de compte.
void setCachedUserRole(Ref ref, UserRole role, {bool force = false}) {
  final current = ref.read(cachedUserRoleProvider);
  if (force || current == UserRole.unknown) {
    ref.read(cachedUserRoleProvider.notifier).state = role;
  }
  // Si current != unknown et force == false → écriture silencieusement ignorée.
  // Le premier writer gagne, les écrits concurrents sont idempotents.
}
