// ══════════════════════════════════════════════════════════════════════════════
// WorkersService — Facade over UsersService
//
// PATTERN: Facade / View
//   This service does NOT inject a Mongoose model. It delegates every operation
//   to UsersService with an implicit role='worker' filter.
//
// WHY A FACADE INSTEAD OF REMOVING THE CLASS ENTIRELY?
//   • WorkersController, LocationService, and the gateway already depend on
//     WorkersService by name. The facade lets those callers stay unchanged.
//   • If you later expose a separate `WorkersModule` to a micro-service, this
//     boundary is already in place.
//   • Zero business logic lives here — it is a typed, documented gateway into
//     the role-discriminated subset of the users collection.
//
// ADDING A NEW WORKER OPERATION:
//   1. Add the method to UsersService (with role=worker filter).
//   2. Add a one-line delegation here.
//   3. Done — WorkersController picks it up automatically.
// ══════════════════════════════════════════════════════════════════════════════

import { Injectable } from '@nestjs/common';
import { UsersService, UserFilters } from '../users/users.service';
import { UserDocument }              from '../../schemas/user.schema';
import { CreateWorkerDto }           from '../../dto/create-worker.dto';
import { UpdateWorkerDto }           from '../../dto/update-worker.dto';

export interface WorkerFilters extends Omit<UserFilters, 'role'> {}

@Injectable()
export class WorkersService {
  constructor(private readonly usersService: UsersService) {}

  // ── CRUD ──────────────────────────────────────────────────────────────────

  async upsert(dto: CreateWorkerDto): Promise<UserDocument> {
    return this.usersService.upsertWorker(dto);
  }

  async findById(id: string): Promise<UserDocument> {
    return this.usersService.findWorkerById(id);
  }

  async findByIdOrNull(id: string): Promise<UserDocument | null> {
    return this.usersService.findWorkerByIdOrNull(id);
  }

  async findMany(filters: WorkerFilters): Promise<UserDocument[]> {
    return this.usersService.findWorkers(filters);
  }

  async update(id: string, dto: UpdateWorkerDto): Promise<UserDocument> {
    return this.usersService.updateWorker(id, dto);
  }

  // ── Status ────────────────────────────────────────────────────────────────

  async updateStatus(id: string, isOnline: boolean): Promise<void> {
    return this.usersService.updateWorkerStatus(id, isOnline);
  }

  // ── Location ──────────────────────────────────────────────────────────────

  async updateLocation(
    id: string,
    latitude: number,
    longitude: number,
    cellId?: string,
    wilayaCode?: number,
    geoHash?: string,
  ): Promise<void> {
    return this.usersService.updateWorkerLocation(id, latitude, longitude, cellId, wilayaCode, geoHash);
  }

  // ── FCM ───────────────────────────────────────────────────────────────────

  async updateFcmToken(id: string, fcmToken: string): Promise<void> {
    return this.usersService.updateWorkerFcmToken(id, fcmToken);
  }

  // ── Rating ────────────────────────────────────────────────────────────────

  /**
   * Apply Bayesian average rating update when a new review comes in.
   * Delegates to UsersService — single authoritative implementation.
   */
  async applyRating(id: string, stars: number): Promise<void> {
    return this.usersService.applyRating(id, stars);
  }
}
