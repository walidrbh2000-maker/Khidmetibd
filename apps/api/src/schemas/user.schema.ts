// ══════════════════════════════════════════════════════════════════════════════
// User Schema — Unified collection for ALL users (clients & workers)
//
// DESIGN RATIONALE:
//   Every worker is a user — there is no scenario where a worker exists without
//   a user identity. Maintaining two collections (users + workers) duplicated
//   identity fields (name, email, phone, location, fcmToken, profileImageUrl)
//   and forced every service to manage two write paths, two cache entries, and
//   two transaction legs for every auth operation.
//
//   The unified design:
//     • Eliminates duplication — one document per person, always.
//     • Simplifies auth: registration, login, and profile update touch one doc.
//     • `role: 'client' | 'worker'` is the single discriminator.
//     • Worker-specific fields (profession, isOnline, rating…) default to
//       neutral values so client queries never see "online" workers and vice-versa.
//     • Partial indexes restrict heavy worker indexes to role='worker' documents,
//       keeping the index footprint proportional to the actual worker count.
//
// PHONE AUTH — index email :
//   Les utilisateurs authentifiés par téléphone peuvent n'avoir aucun email.
//   L'index email est désormais partiel (partialFilterExpression: email ≠ '')
//   pour ne contraindre l'unicité que sur les emails non vides.
//   Cela évite les collisions entre N utilisateurs avec email = ''.
//
// MIGRATION (run once against production):
//   -- Supprimer l'ancien index unique non-partiel :
//   db.users.dropIndex("email_1");
//
//   -- Créer le nouvel index email partiel :
//   db.users.createIndex(
//     { email: 1 },
//     { unique: true, sparse: true, partialFilterExpression: { email: { $ne: '' } } }
//   );
//
//   -- Créer l'index phoneNumber partiel :
//   db.users.createIndex(
//     { phoneNumber: 1 },
//     { unique: true, sparse: true, partialFilterExpression: { phoneNumber: { $ne: '' } } }
//   );
//
//   -- Migrer les workers :
//   db.workers.find().forEach(w => {
//     w.role = 'worker';
//     db.users.updateOne({ _id: w._id }, { $set: w }, { upsert: true });
//   });
//   db.workers.drop();
// ══════════════════════════════════════════════════════════════════════════════

import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document } from 'mongoose';

export enum UserRole {
  Client = 'client',
  Worker = 'worker',
}

export type UserDocument = User & Document;

/**
 * Backward-compatible type alias so existing code importing WorkerDocument
 * from this module compiles without changes.
 */
export type WorkerDocument = UserDocument;

@Schema({ collection: 'users', timestamps: false, versionKey: false })
export class User {
  // ── Identity ────────────────────────────────────────────────────────────────
  @Prop({ required: true, index: true })
  _id: string;                         // Firebase UID — same for client & worker

  @Prop({ required: true })
  name: string;

  /**
   * Email — optionnel pour les utilisateurs Phone Auth (peut être '').
   * L'index MongoDB est partiel : unicité appliquée uniquement si email ≠ ''.
   */
  @Prop({ default: '', lowercase: true, trim: true })
  email: string;

  /**
   * Numéro de téléphone au format E.164 (+213XXXXXXXXX pour l'Algérie).
   * Champ principal d'identification pour les utilisateurs Phone Auth.
   * Index partiel : uniquement si phoneNumber ≠ ''.
   */
  @Prop({ default: '' })
  phoneNumber: string;

  @Prop({
    required: true,
    enum: Object.values(UserRole),
    default: UserRole.Client,
    index: true,
  })
  role: UserRole;

  // ── Location (shared) ────────────────────────────────────────────────────────
  @Prop({ type: Number, default: null })
  latitude: number | null;

  @Prop({ type: Number, default: null })
  longitude: number | null;

  @Prop({ required: true, type: Date })
  lastUpdated: Date;

  @Prop({ type: String, default: null })
  cellId: string | null;

  @Prop({ type: Number, default: null })
  wilayaCode: number | null;

  @Prop({ type: String, default: null })
  geoHash: string | null;

  @Prop({ type: Date, default: null })
  lastCellUpdate: Date | null;

  // ── Media / push (shared) ────────────────────────────────────────────────────
  @Prop({ type: String, default: null })
  profileImageUrl: string | null;

  @Prop({ type: String, default: null })
  fcmToken: string | null;

  // ── Worker-specific ──────────────────────────────────────────────────────────
  // Defaults guarantee that client documents never satisfy worker-targeted
  // queries (e.g. { role: 'worker', isOnline: true }).

  /** Trade / profession key (null for clients). */
  @Prop({ type: String, default: null })
  profession: string | null;

  /** Online status — meaningful only for workers. Always false for clients. */
  @Prop({ default: false })
  isOnline: boolean;

  /** Bayesian average rating (0–5). */
  @Prop({ default: 0.0, min: 0, max: 5 })
  averageRating: number;

  @Prop({ default: 0, min: 0 })
  ratingCount: number;

  /** Running sum of stars — enables Bayesian recomputation without history. */
  @Prop({ default: 0, min: 0 })
  ratingSum: number;

  @Prop({ default: 0, min: 0 })
  jobsCompleted: number;

  /** Fraction of bids responded to (0–1). */
  @Prop({ default: 0.7, min: 0, max: 1 })
  responseRate: number;

  /** Timestamp of last offline transition — used for recency ranking. */
  @Prop({ type: Date, default: null })
  lastActiveAt: Date | null;
}

export const UserSchema = SchemaFactory.createForClass(User);

// ── Shared indexes ────────────────────────────────────────────────────────────

/**
 * Email unique — partiel : uniquement si email ≠ ''.
 * Compatible avec les utilisateurs Phone Auth qui n'ont pas d'email.
 *
 * ⚠️ MIGRATION : supprimer "email_1" (unique non-partiel) en production
 *    avant de déployer cette version.
 */
UserSchema.index(
  { email: 1 },
  {
    unique: true,
    sparse: true,
    partialFilterExpression: { email: { $ne: '' } },
  },
);

/**
 * PhoneNumber unique — partiel : uniquement si phoneNumber ≠ ''.
 * Garantit qu'un numéro de téléphone E.164 ne peut être lié qu'à un seul compte.
 */
UserSchema.index(
  { phoneNumber: 1 },
  {
    unique: true,
    sparse: true,
    partialFilterExpression: { phoneNumber: { $ne: '' } },
  },
);

UserSchema.index({ wilayaCode: 1 });
UserSchema.index({ geoHash: 1 });

// ── Partial indexes (role = 'worker' documents only) ──────────────────────────
// MongoDB partial indexes only maintain index entries for documents satisfying
// the partialFilterExpression. Client documents are invisible to these indexes,
// keeping storage and write amplification proportional to the worker count.
const WORKER_ONLY = { partialFilterExpression: { role: UserRole.Worker } } as const;

UserSchema.index({ isOnline: 1, wilayaCode: 1 },             WORKER_ONLY);
UserSchema.index({ isOnline: 1, profession: 1 },             WORKER_ONLY);
UserSchema.index({ wilayaCode: 1, profession: 1 },           WORKER_ONLY);
UserSchema.index({ cellId: 1, profession: 1, isOnline: 1 },  WORKER_ONLY);
UserSchema.index({ wilayaCode: 1, isOnline: 1 },             WORKER_ONLY);
