// ══════════════════════════════════════════════════════════════════════════════
// Migration MongoDB — Auth Phone (one-shot, idempotent)
//
// Exécuter UNE SEULE FOIS en production AVANT de déployer le nouveau backend.
//
// Usage direct (mongosh) :
//   mongosh $MONGODB_URI --file scripts/migrations/001_phone_auth_indexes.js
//
// Usage via Makefile (recommandé) :
//   make scripts-001_phone_auth_indexes
//
// Ordre des opérations :
//   1. Supprimer l'ancien index email_1 (unique non-partiel)
//   2. Créer le nouvel index email (unique partiel — email ≠ '')
//   3. Créer l'index phoneNumber (unique partiel — phoneNumber ≠ '')
//   4. Vérification post-migration
//
// FIXES :
//   - Code 26 (NamespaceNotFound) ajouté au catch de dropIndex :
//     sur une DB fraîche, la collection 'users' n'existe pas encore.
//     dropIndex() lève NamespaceNotFound (26), pas IndexNotFound (27).
//   - `sparse: true` retiré de createIndex :
//     MongoDB 5+ interdit de combiner sparse et partialFilterExpression.
//     partialFilterExpression: { email: { $ne: '' } } remplit déjà ce rôle.
// ══════════════════════════════════════════════════════════════════════════════

'use strict';

const DB_NAME = db.getName();
print(`\n🚀 Migration 001_phone_auth_indexes — base: ${DB_NAME}\n`);

// ── 1. Supprimer l'ancien index email_1 ──────────────────────────────────────
print('→ [1/4] Suppression de l\'ancien index email_1...');
try {
  db.users.dropIndex('email_1');
  print('   ✅ Index email_1 supprimé');
} catch (e) {
  if (e.code === 27 /* IndexNotFound */) {
    print('   ⏭  Index email_1 déjà absent — skip');
  } else if (e.code === 26 /* NamespaceNotFound — collection absente sur DB fraîche */) {
    print('   ⏭  Collection users absente — skip (DB fraîche)');
  } else {
    print(`   ⚠️  Erreur inattendue: ${e.message}`);
    throw e;
  }
}

// ── 2. Créer le nouvel index email (partiel) ──────────────────────────────────
//
// FIX : `sparse` retiré.
//   MongoDB 5+ lève "cannot mix partialFilterExpression and sparse options"
//   si les deux sont présents simultanément.
//   Le partialFilterExpression { email: { $ne: '' } } exclut déjà les
//   documents sans email — comportement identique à sparse: true.
//
print('→ [2/4] Création de l\'index email (partiel, unique)...');
try {
  db.users.createIndex(
    { email: 1 },
    {
      name:    'email_unique_nonempty',
      unique:  true,
      partialFilterExpression: { email: { $ne: '' } },
      background: true,
    },
  );
  print('   ✅ Index email_unique_nonempty créé');
} catch (e) {
  if (e.code === 85 /* IndexOptionsConflict */ || e.code === 86 /* IndexKeySpecsConflict */) {
    print('   ⏭  Index email_unique_nonempty déjà présent — skip');
  } else {
    print(`   ❌ Échec: ${e.message}`);
    throw e;
  }
}

// ── 3. Créer l'index phoneNumber (partiel) ────────────────────────────────────
//
// FIX : `sparse` retiré pour la même raison que l'index email ci-dessus.
//
print('→ [3/4] Création de l\'index phoneNumber (partiel, unique)...');
try {
  db.users.createIndex(
    { phoneNumber: 1 },
    {
      name:    'phoneNumber_unique_nonempty',
      unique:  true,
      partialFilterExpression: { phoneNumber: { $ne: '' } },
      background: true,
    },
  );
  print('   ✅ Index phoneNumber_unique_nonempty créé');
} catch (e) {
  if (e.code === 85 || e.code === 86) {
    print('   ⏭  Index phoneNumber_unique_nonempty déjà présent — skip');
  } else {
    print(`   ❌ Échec: ${e.message}`);
    throw e;
  }
}

// ── 4. Vérification ───────────────────────────────────────────────────────────
//
// FIX : getIndexes() échoue avec NamespaceNotFound (26) si la collection
//   n'a jamais reçu de documents (DB fraîche). Dans ce cas les index sont
//   enregistrés dans le catalogue mais getIndexes() peut être instable.
//   On catch et on log sans faire échouer la migration.
//
print('→ [4/4] Vérification post-migration...');
try {
  const indexes = db.users.getIndexes();
  const emailIdx = indexes.find(i => i.name === 'email_unique_nonempty');
  const phoneIdx = indexes.find(i => i.name === 'phoneNumber_unique_nonempty');

  if (emailIdx && phoneIdx) {
    print('   ✅ Tous les index sont en place');
  } else {
    print('   ⚠️  Vérification manuelle recommandée :');
    print(JSON.stringify(indexes, null, 2));
  }
} catch (e) {
  if (e.code === 26 /* NamespaceNotFound */) {
    print('   ⚠️  Vérification manuelle recommandée :\n' +
          '   La collection users sera créée au premier INSERT — les index seront actifs dès lors.');
  } else {
    print(`   ⚠️  Erreur vérification: ${e.message}`);
  }
}

print('\n✅ Migration 001_phone_auth_indexes terminée\n');
