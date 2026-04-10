// ══════════════════════════════════════════════════════════════════════════════
// UsersService — Unified service for ALL users (clients and workers)
//
// Architecture:
//   • One Model<UserDocument> is injected — queries are discriminated by `role`.
//   • Worker-facing methods are grouped under the "Worker API" section.
//   • WorkersService is a thin facade that calls these methods with the correct
//     role filter. No business logic lives in WorkersService.
//   • Bayesian rating is computed here — the single authoritative location.
// ══════════════════════════════════════════════════════════════════════════════

import {
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { FilterQuery, Model } from 'mongoose';
import { User, UserDocument, UserRole } from '../../schemas/user.schema';
import { CreateUserDto }    from '../../dto/create-user.dto';
import { UpdateUserDto }    from '../../dto/update-user.dto';
import { CreateWorkerDto }  from '../../dto/create-worker.dto';
import { UpdateWorkerDto }  from '../../dto/update-worker.dto';

// ── Filter shapes ─────────────────────────────────────────────────────────────

export interface UserFilters {
  role?: UserRole;
  wilayaCode?: number;
  profession?: string;
  isOnline?: boolean;
  cellId?: string;
  limit?: number;
}

// ──────────────────────────────────────────────────────────────────────────────

@Injectable()
export class UsersService {
  private readonly logger = new Logger(UsersService.name);

  constructor(
    @InjectModel(User.name)
    private readonly userModel: Model<UserDocument>,
  ) {}

  // ═══════════════════════════════════════════════════════════════════════════
  // SHARED (client + worker)
  // ═══════════════════════════════════════════════════════════════════════════

  /** Create or update any user document. Role defaults to 'client'. */
  async upsert(dto: CreateUserDto | CreateWorkerDto): Promise<UserDocument> {
    try {
      const role = dto.role ?? UserRole.Client;
      const patch: Partial<Record<string, unknown>> = {
        name:        dto.name,
        email:       dto.email,
        role,
        phoneNumber: dto.phoneNumber ?? '',
        latitude:    dto.latitude    ?? null,
        longitude:   dto.longitude   ?? null,
        profileImageUrl: dto.profileImageUrl ?? null,
        fcmToken:    dto.fcmToken    ?? null,
        lastUpdated: new Date(),
      };

      // Worker-specific fields — only set when explicitly provided
      if ('profession' in dto && dto.profession)       patch['profession'] = dto.profession;
      if ('isOnline'   in dto && dto.isOnline != null) patch['isOnline']   = dto.isOnline;

      const doc = await this.userModel
        .findByIdAndUpdate(dto.id, patch, { upsert: true, new: true, runValidators: true })
        .exec();

      if (!doc) throw new NotFoundException(`User ${dto.id} not found after upsert`);
      return doc;
    } catch (err) {
      this.logger.error('UsersService.upsert failed', err);
      throw err;
    }
  }

  async findById(id: string): Promise<UserDocument> {
    try {
      const doc = await this.userModel.findById(id).exec();
      if (!doc) throw new NotFoundException(`User ${id} not found`);
      return doc;
    } catch (err) {
      this.logger.error(`UsersService.findById(${id}) failed`, err);
      throw err;
    }
  }

  async findByIdOrNull(id: string): Promise<UserDocument | null> {
    return this.userModel.findById(id).exec();
  }

  async findMany(filters: UserFilters): Promise<UserDocument[]> {
    try {
      const query: FilterQuery<User> = {};
      if (filters.role       != null) query.role       = filters.role;
      if (filters.wilayaCode != null) query.wilayaCode = filters.wilayaCode;
      if (filters.profession)         query.profession  = filters.profession;
      if (filters.isOnline   != null) query.isOnline   = filters.isOnline;
      if (filters.cellId)             query.cellId      = filters.cellId;

      const limit = Math.min(filters.limit ?? 100, 200);
      return this.userModel.find(query).limit(limit).exec();
    } catch (err) {
      this.logger.error('UsersService.findMany failed', err);
      throw err;
    }
  }

  async update(id: string, dto: UpdateUserDto): Promise<UserDocument> {
    try {
      const patch: Partial<Record<string, unknown>> = { lastUpdated: new Date() };
      if (dto.name             != null) patch['name']            = dto.name;
      if (dto.phoneNumber      != null) patch['phoneNumber']     = dto.phoneNumber;
      if (dto.profileImageUrl  != null) patch['profileImageUrl'] = dto.profileImageUrl;
      if (dto.cellId           != null) patch['cellId']          = dto.cellId;
      if (dto.wilayaCode       != null) patch['wilayaCode']      = dto.wilayaCode;
      if (dto.geoHash          != null) patch['geoHash']         = dto.geoHash;

      const doc = await this.userModel
        .findByIdAndUpdate(id, patch, { new: true, runValidators: true })
        .exec();
      if (!doc) throw new NotFoundException(`User ${id} not found`);
      return doc;
    } catch (err) {
      this.logger.error(`UsersService.update(${id}) failed`, err);
      throw err;
    }
  }

  async updateLocation(
    id: string,
    latitude: number,
    longitude: number,
    cellId?: string,
    wilayaCode?: number,
    geoHash?: string,
  ): Promise<void> {
    try {
      const patch: Partial<Record<string, unknown>> = {
        latitude,
        longitude,
        lastUpdated: new Date(),
      };
      if (cellId     != null) { patch['cellId']       = cellId;     patch['lastCellUpdate'] = new Date(); }
      if (wilayaCode != null)   patch['wilayaCode']   = wilayaCode;
      if (geoHash    != null)   patch['geoHash']      = geoHash;

      const result = await this.userModel.updateOne({ _id: id }, patch).exec();
      if (result.matchedCount === 0) throw new NotFoundException(`User ${id} not found`);
    } catch (err) {
      this.logger.error(`UsersService.updateLocation(${id}) failed`, err);
      throw err;
    }
  }

  async updateFcmToken(id: string, fcmToken: string): Promise<void> {
    try {
      const result = await this.userModel
        .updateOne({ _id: id }, { fcmToken, lastUpdated: new Date() })
        .exec();
      if (result.matchedCount === 0) throw new NotFoundException(`User ${id} not found`);
    } catch (err) {
      this.logger.error(`UsersService.updateFcmToken(${id}) failed`, err);
      throw err;
    }
  }

  async clearFcmToken(id: string): Promise<void> {
    await this.userModel.updateOne({ _id: id }, { fcmToken: null, lastUpdated: new Date() }).exec();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // WORKER API  (all queries enforce role = 'worker')
  // ═══════════════════════════════════════════════════════════════════════════

  /** Upsert a user document with role='worker'. */
  async upsertWorker(dto: CreateWorkerDto): Promise<UserDocument> {
    return this.upsert({ ...dto, role: UserRole.Worker });
  }

  /** Find a worker by ID (throws 404 if not found OR if role ≠ worker). */
  async findWorkerById(id: string): Promise<UserDocument> {
    try {
      const doc = await this.userModel
        .findOne({ _id: id, role: UserRole.Worker })
        .exec();
      if (!doc) throw new NotFoundException(`Worker ${id} not found`);
      return doc;
    } catch (err) {
      this.logger.error(`UsersService.findWorkerById(${id}) failed`, err);
      throw err;
    }
  }

  /** Same as findWorkerById but returns null instead of throwing. */
  async findWorkerByIdOrNull(id: string): Promise<UserDocument | null> {
    return this.userModel.findOne({ _id: id, role: UserRole.Worker }).exec();
  }

  /** Query workers with optional filters. */
  async findWorkers(filters: Omit<UserFilters, 'role'>): Promise<UserDocument[]> {
    return this.findMany({ ...filters, role: UserRole.Worker });
  }

  async updateWorker(id: string, dto: UpdateWorkerDto): Promise<UserDocument> {
    try {
      const patch: Partial<Record<string, unknown>> = { lastUpdated: new Date() };
      if (dto.name             != null) patch['name']            = dto.name;
      if (dto.phoneNumber      != null) patch['phoneNumber']     = dto.phoneNumber;
      if (dto.profileImageUrl  != null) patch['profileImageUrl'] = dto.profileImageUrl;
      if (dto.cellId           != null) patch['cellId']          = dto.cellId;
      if (dto.wilayaCode       != null) patch['wilayaCode']      = dto.wilayaCode;
      if (dto.geoHash          != null) patch['geoHash']         = dto.geoHash;
      if (dto.averageRating    != null) patch['averageRating']   = dto.averageRating;
      if (dto.ratingCount      != null) patch['ratingCount']     = dto.ratingCount;
      if (dto.jobsCompleted    != null) patch['jobsCompleted']   = dto.jobsCompleted;
      if (dto.responseRate     != null) patch['responseRate']    = dto.responseRate;
      if (dto.lastActiveAt     != null) patch['lastActiveAt']    = dto.lastActiveAt;

      const doc = await this.userModel
        .findOneAndUpdate(
          { _id: id, role: UserRole.Worker },
          patch,
          { new: true, runValidators: true },
        )
        .exec();
      if (!doc) throw new NotFoundException(`Worker ${id} not found`);
      return doc;
    } catch (err) {
      this.logger.error(`UsersService.updateWorker(${id}) failed`, err);
      throw err;
    }
  }

  async updateWorkerStatus(id: string, isOnline: boolean): Promise<void> {
    try {
      const patch: Partial<Record<string, unknown>> = {
        isOnline,
        lastUpdated: new Date(),
      };
      if (!isOnline) patch['lastActiveAt'] = new Date();

      const result = await this.userModel
        .updateOne({ _id: id, role: UserRole.Worker }, patch)
        .exec();
      if (result.matchedCount === 0) throw new NotFoundException(`Worker ${id} not found`);
    } catch (err) {
      this.logger.error(`UsersService.updateWorkerStatus(${id}) failed`, err);
      throw err;
    }
  }

  async updateWorkerLocation(
    id: string,
    latitude: number,
    longitude: number,
    cellId?: string,
    wilayaCode?: number,
    geoHash?: string,
  ): Promise<void> {
    try {
      const patch: Partial<Record<string, unknown>> = {
        latitude,
        longitude,
        lastUpdated: new Date(),
      };
      if (cellId     != null) { patch['cellId'] = cellId; patch['lastCellUpdate'] = new Date(); }
      if (wilayaCode != null) patch['wilayaCode'] = wilayaCode;
      if (geoHash    != null) patch['geoHash']    = geoHash;

      const result = await this.userModel
        .updateOne({ _id: id, role: UserRole.Worker }, patch)
        .exec();
      if (result.matchedCount === 0) throw new NotFoundException(`Worker ${id} not found`);
    } catch (err) {
      this.logger.error(`UsersService.updateWorkerLocation(${id}) failed`, err);
      throw err;
    }
  }

  async updateWorkerFcmToken(id: string, fcmToken: string): Promise<void> {
    try {
      const result = await this.userModel
        .updateOne({ _id: id, role: UserRole.Worker }, { fcmToken, lastUpdated: new Date() })
        .exec();
      if (result.matchedCount === 0) throw new NotFoundException(`Worker ${id} not found`);
    } catch (err) {
      this.logger.error(`UsersService.updateWorkerFcmToken(${id}) failed`, err);
      throw err;
    }
  }

  /**
   * Apply Bayesian average rating update.
   *
   * Formula: (m × C + Σratings) / (m + n)
   *   C = 3.5 (global average)   m = 10 (confidence weight)
   */
  async applyRating(id: string, stars: number): Promise<void> {
    try {
      const worker = await this.userModel
        .findOne({ _id: id, role: UserRole.Worker })
        .select('ratingCount ratingSum averageRating')
        .exec();

      if (!worker) throw new NotFoundException(`Worker ${id} not found`);

      const oldCount = worker.ratingCount ?? 0;
      const oldSum   = worker.ratingSum   ?? (worker.averageRating * oldCount);
      const newCount = oldCount + 1;
      const newSum   = oldSum + stars;

      const C = 3.5;
      const m = 10;
      const bayesianAvg = (m * C + newSum) / (m + newCount);

      await this.userModel.updateOne(
        { _id: id, role: UserRole.Worker },
        {
          averageRating: bayesianAvg,
          ratingCount:   newCount,
          ratingSum:     newSum,
          lastUpdated:   new Date(),
        },
      ).exec();
    } catch (err) {
      this.logger.error(`UsersService.applyRating(${id}) failed`, err);
      throw err;
    }
  }

  // ── Stream helper (for location gateway) ─────────────────────────────────
  async getWorkerForGateway(
    uid: string,
  ): Promise<Pick<UserDocument, 'wilayaCode' | 'profession' | 'isOnline'> | null> {
    return this.userModel
      .findOne({ _id: uid, role: UserRole.Worker })
      .select('wilayaCode profession isOnline')
      .lean()
      .exec() as any;
  }
}
