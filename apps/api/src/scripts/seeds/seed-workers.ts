// ══════════════════════════════════════════════════════════════════════════════
// KHIDMETI — Script de seed : travailleurs de test à Oran (Wahran)
//
// USAGE via Makefile (recommandé — aucune installation requise) :
//   make scripts-seed-workers              ← seed initial
//   make scripts-seed-workers ARGS=--clear ← efface + re-seed
//
// USAGE direct (si ts-node installé sur l'hôte) :
//   npx ts-node --project tsconfig.json src/scripts/seeds/seed-workers.ts
//   npx ts-node --project tsconfig.json src/scripts/seeds/seed-workers.ts --clear
//
// IMPORTANT :
//   Ces workers ont des UIDs fictifs (seed-worker-XXX).
//   Ils sont visibles dans MongoDB et dans l'API REST,
//   mais ne peuvent PAS se connecter via Firebase Auth.
//   → Parfait pour tester : browsing worker, cartes, recherche IA.
//
// FIX — geographic_cells vides :
//   Le seed précédent créait les workers avec un cellId mais n'insérait pas
//   les documents GeographicCell correspondants. L'endpoint
//   GET /location/cells/:cellId/workers fonctionnait (requête sur users)
//   mais GET /location/cells/:cellId/adjacent retournait une erreur car
//   la collection geographic_cells était vide.
//   Ce script crée désormais toutes les GeographicCell nécessaires.
// ══════════════════════════════════════════════════════════════════════════════

import mongoose from 'mongoose';

// ── Config ────────────────────────────────────────────────────────────────────
const MONGODB_URI =
  process.env['MONGODB_URI'] ??
  'mongodb://khidmeti:khidmeti123@localhost:27017/khidmeti?authSource=admin';

// Oran (Wahran) — wilayaCode = 31
const WILAYA_CODE = 31;

// ── Coordonnées de quartiers d'Oran pour avoir des workers répartis ───────────
const ORAN_LOCATIONS = [
  { name: 'Es Senia',       lat: 35.6481,  lng: -0.6030 },
  { name: 'Bir El Djir',    lat: 35.7128,  lng: -0.5538 },
  { name: 'Oran Centre',    lat: 35.6969,  lng: -0.6331 },
  { name: 'Hay Yasmine',    lat: 35.6750,  lng: -0.6200 },
  { name: 'Plateaux',       lat: 35.7050,  lng: -0.6500 },
  { name: 'Gambetta',       lat: 35.7110,  lng: -0.6420 },
  { name: 'Belgaid',        lat: 35.6600,  lng: -0.6700 },
  { name: 'Sidi El Bachir', lat: 35.6850,  lng: -0.6100 },
];

// ── Données des travailleurs de test ──────────────────────────────────────────
const TEST_WORKERS = [
  {
    uid:        'seed-worker-001',
    name:       'Karim Benali',
    phone:      '+213550111001',
    profession: 'plumber',
    rating:     4.7,
    jobs:       34,
    location:   ORAN_LOCATIONS[0],
  },
  {
    uid:        'seed-worker-002',
    name:       'Farid Boumediene',
    phone:      '+213550111002',
    profession: 'electrician',
    rating:     4.5,
    jobs:       28,
    location:   ORAN_LOCATIONS[1],
  },
  {
    uid:        'seed-worker-003',
    name:       'Mohamed Tlemcani',
    phone:      '+213550111003',
    profession: 'plumber',
    rating:     4.2,
    jobs:       19,
    location:   ORAN_LOCATIONS[2],
  },
  {
    uid:        'seed-worker-004',
    name:       'Youcef Hadjadj',
    phone:      '+213550111004',
    profession: 'ac_repair',
    rating:     4.8,
    jobs:       52,
    location:   ORAN_LOCATIONS[3],
  },
  {
    uid:        'seed-worker-005',
    name:       'Amine Zerrouk',
    phone:      '+213550111005',
    profession: 'mason',
    rating:     4.0,
    jobs:       11,
    location:   ORAN_LOCATIONS[4],
  },
  {
    uid:        'seed-worker-006',
    name:       'Rachid Kaci',
    phone:      '+213550111006',
    profession: 'painter',
    rating:     4.3,
    jobs:       22,
    location:   ORAN_LOCATIONS[5],
  },
  {
    uid:        'seed-worker-007',
    name:       'Bilal Messaoudi',
    phone:      '+213550111007',
    profession: 'electrician',
    rating:     4.6,
    jobs:       41,
    location:   ORAN_LOCATIONS[6],
  },
  {
    uid:        'seed-worker-008',
    name:       'Nabil Brahimi',
    phone:      '+213550111008',
    profession: 'cleaner',
    rating:     4.1,
    jobs:       16,
    location:   ORAN_LOCATIONS[7],
  },
  {
    uid:        'seed-worker-009',
    name:       'Samir Bouali',
    phone:      '+213550111009',
    profession: 'carpenter',
    rating:     4.4,
    jobs:       30,
    location:   ORAN_LOCATIONS[0],
  },
  {
    uid:        'seed-worker-010',
    name:       'Hichem Djebari',
    phone:      '+213550111010',
    profession: 'appliance_repair',
    rating:     4.9,
    jobs:       67,
    location:   ORAN_LOCATIONS[1],
  },
  // Quelques workers HORS LIGNE pour tester les filtres
  {
    uid:        'seed-worker-011',
    name:       'Omar Laid',
    phone:      '+213550111011',
    profession: 'plumber',
    rating:     3.8,
    jobs:       8,
    location:   ORAN_LOCATIONS[2],
    isOnline:   false,
  },
  {
    uid:        'seed-worker-012',
    name:       'Khaled Mansouri',
    phone:      '+213550111012',
    profession: 'mechanic',
    rating:     4.2,
    jobs:       25,
    location:   ORAN_LOCATIONS[3],
    isOnline:   false,
  },
];

// ── Mongoose Schema : users (minimal — identique à user.schema.ts) ────────────
const UserSchema = new mongoose.Schema(
  {
    _id:            { type: String, required: true },
    name:           { type: String, required: true },
    email:          { type: String, default: '' },
    phoneNumber:    { type: String, default: '' },
    role:           { type: String, default: 'worker' },
    latitude:       { type: Number, default: null },
    longitude:      { type: Number, default: null },
    wilayaCode:     { type: Number, default: null },
    cellId:         { type: String, default: null },
    geoHash:        { type: String, default: null },
    lastUpdated:    { type: Date,   required: true },
    lastCellUpdate: { type: Date,   default: null },
    profileImageUrl:{ type: String, default: null },
    fcmToken:       { type: String, default: null },
    profession:     { type: String, default: null },
    isOnline:       { type: Boolean, default: false },
    averageRating:  { type: Number, default: 0 },
    ratingCount:    { type: Number, default: 0 },
    ratingSum:      { type: Number, default: 0 },
    jobsCompleted:  { type: Number, default: 0 },
    responseRate:   { type: Number, default: 0.7 },
    lastActiveAt:   { type: Date,   default: null },
  },
  { collection: 'users', versionKey: false },
);

// ── Mongoose Schema : geographic_cells (identique à geographic-cell.schema.ts)
// FIX: ajout de ce schéma pour créer les cellules manquantes.
const GeoCellSchema = new mongoose.Schema(
  {
    _id:            { type: String, required: true },
    wilayaCode:     { type: Number, required: true },
    centerLat:      { type: Number, required: true },
    centerLng:      { type: Number, required: true },
    radius:         { type: Number, default: 5.0 },
    adjacentCellIds:{ type: [String], default: [] },
  },
  { collection: 'geographic_cells', versionKey: false },
);

// ── Helpers ───────────────────────────────────────────────────────────────────

const CELL_PRECISION = 2;

/** Construit le cellId (identique à LocationService.buildCellId) */
function buildCellId(lat: number, lng: number, wilayaCode: number): string {
  const rLat = +lat.toFixed(CELL_PRECISION);
  const rLng = +lng.toFixed(CELL_PRECISION);
  return `${wilayaCode}_${rLat.toFixed(CELL_PRECISION)}_${rLng.toFixed(CELL_PRECISION)}`;
}

/** Retourne les 8 cellIds adjacents (identique à LocationService.getAdjacentCellIds) */
function getAdjacentCellIds(cellId: string): string[] {
  const parts = cellId.split('_');
  if (parts.length !== 3) return [];
  const [wilayaStr, latStr, lngStr] = parts;
  const wilayaCode = parseInt(wilayaStr, 10);
  const lat  = parseFloat(latStr);
  const lng  = parseFloat(lngStr);
  const step = Math.pow(10, -CELL_PRECISION);

  const ids: string[] = [];
  for (let dLat = -1; dLat <= 1; dLat++) {
    for (let dLng = -1; dLng <= 1; dLng++) {
      if (dLat === 0 && dLng === 0) continue;
      const adjLat = +(lat + dLat * step).toFixed(CELL_PRECISION);
      const adjLng = +(lng + dLng * step).toFixed(CELL_PRECISION);
      ids.push(`${wilayaCode}_${adjLat.toFixed(CELL_PRECISION)}_${adjLng.toFixed(CELL_PRECISION)}`);
    }
  }
  return ids;
}

/** Encode un geohash à précision 6 (identique à LocationService.encodeGeoHash) */
function encodeGeoHash(lat: number, lng: number, precision = 6): string {
  const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
  let hash = '', isEven = true, bit = 0, ch = 0;
  let latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  while (hash.length < precision) {
    let mid: number;
    if (isEven) {
      mid = (lngMin + lngMax) / 2;
      if (lng >= mid) { ch |= (1 << (4 - bit)); lngMin = mid; } else { lngMax = mid; }
    } else {
      mid = (latMin + latMax) / 2;
      if (lat >= mid) { ch |= (1 << (4 - bit)); latMin = mid; } else { latMax = mid; }
    }
    isEven = !isEven;
    if (bit < 4) { bit++; } else { hash += BASE32[ch]; bit = 0; ch = 0; }
  }
  return hash;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  const shouldClear = process.argv.includes('--clear');

  console.log('\n══════════════════════════════════════════════');
  console.log('  Khidmeti — Seed : workers de test (Oran)');
  console.log('══════════════════════════════════════════════\n');

  await mongoose.connect(MONGODB_URI);
  console.log('✅ Connecté à MongoDB\n');

  const UserModel    = mongoose.model('User',            UserSchema);
  const GeoCellModel = mongoose.model('GeographicCell',  GeoCellSchema);

  // ── Nettoyage optionnel ─────────────────────────────────────────────────────
  if (shouldClear) {
    const delWorkers = await UserModel.deleteMany({ _id: /^seed-worker-/ });
    const delCells   = await GeoCellModel.deleteMany({
      _id: { $in: TEST_WORKERS.map(w => buildCellId(w.location.lat, w.location.lng, WILAYA_CODE)) },
    });
    console.log(`🗑️  ${delWorkers.deletedCount} worker(s) seed supprimés`);
    console.log(`🗑️  ${delCells.deletedCount} cellule(s) seed supprimées\n`);
  }

  // ── Seed des workers ────────────────────────────────────────────────────────
  console.log('  Workers :');
  let workerCreated = 0;
  let workerSkipped = 0;

  for (const w of TEST_WORKERS) {
    const { lat, lng } = w.location;
    const cellId  = buildCellId(lat, lng, WILAYA_CODE);
    const geoHash = encodeGeoHash(lat, lng, 6);

    // Bayesian average identique à UsersService.applyRating()
    const ratingSum   = w.rating * w.jobs;
    const C = 3.5, m = 10;
    const bayesianAvg = (m * C + ratingSum) / (m + w.jobs);

    const doc = {
      _id:            w.uid,
      name:           w.name,
      email:          '',
      phoneNumber:    w.phone,
      role:           'worker',
      latitude:       lat,
      longitude:      lng,
      wilayaCode:     WILAYA_CODE,
      cellId,
      geoHash,
      lastUpdated:    new Date(),
      lastCellUpdate: new Date(),
      profileImageUrl: null,
      fcmToken:        null,
      profession:      w.profession,
      isOnline:        w.isOnline ?? true,
      averageRating:   bayesianAvg,
      ratingCount:     w.jobs,
      ratingSum,
      jobsCompleted:   w.jobs,
      responseRate:    0.85,
      lastActiveAt:    null,
    };

    try {
      await UserModel.create(doc);
      workerCreated++;
      console.log(
        `  ✅ ${w.name.padEnd(22)} | ${w.profession.padEnd(16)} ` +
        `| ${w.location.name.padEnd(15)} ` +
        `| ${w.isOnline ?? true ? '🟢 en ligne' : '⚫ hors ligne'}`,
      );
    } catch (err: any) {
      if (err.code === 11000) {
        workerSkipped++;
        console.log(`  ⏭️  ${w.name} déjà existant — ignoré`);
      } else {
        throw err;
      }
    }
  }

  // ── FIX: Seed des GeographicCell ───────────────────────────────────────────
  // Collecte les cellIds uniques de tous les workers et les upsert.
  // Sans ces documents, GET /location/cells/:cellId/adjacent échoue et
  // les clients qui démarrent avec un cellId ne trouvent pas les workers voisins.
  console.log('\n  Cellules géographiques :');
  let cellCreated = 0;
  let cellSkipped = 0;

  // Utiliser un Map pour dédupliquer les cellIds (plusieurs workers peuvent
  // partager la même cellule car buildCellId arrondit à 2 décimales).
  const uniqueCells = new Map<string, { lat: number; lng: number }>();
  for (const w of TEST_WORKERS) {
    const cellId = buildCellId(w.location.lat, w.location.lng, WILAYA_CODE);
    if (!uniqueCells.has(cellId)) {
      uniqueCells.set(cellId, { lat: w.location.lat, lng: w.location.lng });
    }
  }

  for (const [cellId, { lat, lng }] of uniqueCells) {
    const adjacentCellIds = getAdjacentCellIds(cellId);

    const cellDoc = {
      wilayaCode:     WILAYA_CODE,
      centerLat:      +lat.toFixed(CELL_PRECISION),
      centerLng:      +lng.toFixed(CELL_PRECISION),
      radius:         5.0,
      adjacentCellIds,
    };

    try {
      // findByIdAndUpdate + upsert = idempotent : crée si absent, no-op si présent.
      const result = await GeoCellModel.findByIdAndUpdate(
        cellId,
        { $setOnInsert: cellDoc },
        { upsert: true, new: false },
      ).exec();

      if (result === null) {
        // null returned by findByIdAndUpdate when upsert creates a new doc
        cellCreated++;
        console.log(`  ✅ Cellule créée : ${cellId}`);
      } else {
        cellSkipped++;
        console.log(`  ⏭️  Cellule déjà existante : ${cellId}`);
      }
    } catch (err: any) {
      if (err.code === 11000) {
        cellSkipped++;
        console.log(`  ⏭️  Cellule déjà existante : ${cellId}`);
      } else {
        throw err;
      }
    }
  }

  // ── Résumé ─────────────────────────────────────────────────────────────────
  console.log('\n══════════════════════════════════════════════');
  console.log(`  Workers  : ✅ ${workerCreated} créé(s)  |  ⏭️  ${workerSkipped} ignoré(s)`);
  console.log(`  Cellules : ✅ ${cellCreated} créée(s)  |  ⏭️  ${cellSkipped} ignorée(s)`);
  console.log('══════════════════════════════════════════════');
  console.log('\n  Tests rapides :');
  console.log('  curl http://localhost:3000/workers?wilayaCode=31&isOnline=true');
  console.log('  curl http://localhost:3000/workers?wilayaCode=31&profession=plumber');
  console.log('  curl http://localhost:3000/location/cells/31_35.65_-0.60/adjacent\n');

  await mongoose.disconnect();
}

main().catch((err) => {
  console.error('\n❌ Erreur :', err.message);
  process.exit(1);
});
