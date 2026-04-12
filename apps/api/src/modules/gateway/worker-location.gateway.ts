// apps/api/src/modules/gateway/worker-location.gateway.ts
//
// FIX: Repeated "Worker not found" errors in logs
//
// ROOT CAUSE:
//   On every WebSocket connection to /workers namespace, handleConnection()
//   performs a MongoDB findOne({ _id: uid, role: 'worker' }).
//   When a CLIENT connects to this namespace (which happens because Flutter
//   uses the same socket URL for location updates), the query returns null,
//   socket.data.isWorker = false, and "Worker not found" is logged as WARNING.
//   This is NOT an error — it's expected behavior — but the repeated logs
//   create noise that hides real errors.
//
// FIX:
//   1. Cache the worker lookup result per UID in a WeakMap to avoid repeated
//      DB queries when the same worker reconnects.
//   2. Downgrade "non-worker connected" from WARN to DEBUG.
//   3. Add connection debouncing: if the same UID reconnects within 2s
//      (e.g. React Native reconnect loop), skip the DB lookup and reuse cached result.

import {
  WebSocketGateway,
  WebSocketServer,
  SubscribeMessage,
  MessageBody,
  ConnectedSocket,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import * as admin from 'firebase-admin';
import { InjectModel } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import { User, UserDocument, UserRole } from '../../schemas/user.schema';

interface AuthenticatedSocket extends Socket {
  data: { uid: string; isWorker: boolean; wilayaCode?: number };
}

interface LocationPayload { lat: number; lng: number; }
interface StatusPayload   { isOnline: boolean; }

// ── Worker profile cache ───────────────────────────────────────────────────────
// Avoids one MongoDB query per reconnection. TTL: 5 minutes.
// Structure: uid → { isWorker, wilayaCode, profession, cachedAt }

interface CachedWorkerProfile {
  isWorker:   boolean;
  wilayaCode: number | undefined;
  profession: string | undefined;
  cachedAt:   number;
}

const PROFILE_CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

@WebSocketGateway({
  namespace: '/workers',
  cors: { origin: '*', credentials: false },
  transports: ['websocket', 'polling'],
})
export class WorkerLocationGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer() private readonly server!: Server;
  private readonly logger = new Logger(WorkerLocationGateway.name);

  // Per-uid profile cache — avoids DB query on every reconnect
  private readonly profileCache = new Map<string, CachedWorkerProfile>();

  constructor(
    @InjectModel(User.name)
    private readonly userModel: Model<UserDocument>,
  ) {}

  // ── Connection lifecycle ────────────────────────────────────────────────────

  async handleConnection(socket: AuthenticatedSocket): Promise<void> {
    try {
      const token =
        socket.handshake.auth?.['token'] as string | undefined ??
        (socket.handshake.headers['authorization'] as string | undefined)?.replace('Bearer ', '');

      if (!token) {
        this.logger.debug(`[WS workers] Rejected unauthenticated socket ${socket.id}`);
        socket.disconnect(true);
        return;
      }

      const decoded = await admin.auth().verifyIdToken(token);
      const uid     = decoded.uid;
      socket.data.uid = uid;

      // FIX: Check cache before hitting MongoDB
      const profile = await this.getWorkerProfile(uid);

      socket.data.isWorker   = profile.isWorker;
      socket.data.wilayaCode = profile.wilayaCode;

      if (profile.isWorker) {
        await socket.join(`worker:${uid}`);
        if (profile.wilayaCode) {
          await socket.join(`wilaya:${profile.wilayaCode}`);
        }
        this.logger.log(`[WS workers] Worker ${uid} connected (${socket.id})`);
      } else {
        // FIX: Downgraded from WARN to DEBUG — clients connecting to /workers
        // is expected behaviour (they subscribe to worker locations on the map).
        this.logger.debug(`[WS workers] Viewer ${uid} connected (${socket.id})`);
      }
    } catch (err) {
      this.logger.warn(`[WS workers] Auth failure on socket ${socket.id}: ${err}`);
      socket.disconnect(true);
    }
  }

  handleDisconnect(socket: AuthenticatedSocket): void {
    this.logger.debug(
      `[WS workers] Socket ${socket.id} (uid=${socket.data?.uid ?? 'unknown'}) disconnected`,
    );
  }

  // ── Worker → Server events ──────────────────────────────────────────────────

  @SubscribeMessage('worker:update_location')
  async handleUpdateLocation(
    @ConnectedSocket() socket: AuthenticatedSocket,
    @MessageBody() payload: LocationPayload,
  ): Promise<void> {
    if (!socket.data?.isWorker) return;
    const { lat, lng } = payload;
    if (typeof lat !== 'number' || typeof lng !== 'number') return;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return;

    const workerId = socket.data.uid;

    this.userModel
      .updateOne(
        { _id: workerId, role: UserRole.Worker },
        { latitude: lat, longitude: lng, lastUpdated: new Date() },
      )
      .exec()
      .catch((e: unknown) => this.logger.error('Location persist failed', e));

    // Invalidate cache entry when location changes (wilayaCode may change)
    // — actually wilayaCode only changes on cell reassignment, not on location ping.
    // No need to bust cache here.

    const event = { workerId, lat, lng, ts: Date.now() };
    if (socket.data.wilayaCode) {
      this.server.to(`wilaya:${socket.data.wilayaCode}`).emit('worker:location', event);
    }
    this.server.to(`worker:${workerId}`).emit('worker:location', event);
  }

  @SubscribeMessage('worker:set_status')
  async handleSetStatus(
    @ConnectedSocket() socket: AuthenticatedSocket,
    @MessageBody() payload: StatusPayload,
  ): Promise<void> {
    if (!socket.data?.isWorker) return;
    const { isOnline } = payload;
    if (typeof isOnline !== 'boolean') return;

    const workerId = socket.data.uid;

    await this.userModel
      .updateOne(
        { _id: workerId, role: UserRole.Worker },
        {
          isOnline,
          lastUpdated: new Date(),
          ...(isOnline ? {} : { lastActiveAt: new Date() }),
        },
      )
      .exec();

    // Bust profile cache so next connection reflects updated isOnline
    this.profileCache.delete(workerId);

    const event = { workerId, isOnline, ts: Date.now() };
    if (socket.data.wilayaCode) {
      this.server.to(`wilaya:${socket.data.wilayaCode}`).emit('worker:status', event);
    }
    this.server.to(`worker:${workerId}`).emit('worker:status', event);
  }

  // ── Client → Server: room subscriptions ────────────────────────────────────

  @SubscribeMessage('subscribe:wilaya')
  async handleSubscribeWilaya(
    @ConnectedSocket() socket: AuthenticatedSocket,
    @MessageBody() payload: { wilayaCode: number },
  ): Promise<void> {
    if (!payload?.wilayaCode || typeof payload.wilayaCode !== 'number') return;
    await socket.join(`wilaya:${payload.wilayaCode}`);
  }

  @SubscribeMessage('subscribe:worker')
  async handleSubscribeWorker(
    @ConnectedSocket() socket: AuthenticatedSocket,
    @MessageBody() payload: { workerId: string },
  ): Promise<void> {
    if (!payload?.workerId || typeof payload.workerId !== 'string') return;
    await socket.join(`worker:${payload.workerId}`);
  }

  // ── Server-initiated helpers ─────────────────────────────────────────────────

  emitWorkerLocation(workerId: string, lat: number, lng: number, wilayaCode?: number): void {
    const event = { workerId, lat, lng, ts: Date.now() };
    if (wilayaCode) this.server.to(`wilaya:${wilayaCode}`).emit('worker:location', event);
    this.server.to(`worker:${workerId}`).emit('worker:location', event);
  }

  emitWorkerStatus(workerId: string, isOnline: boolean, wilayaCode?: number): void {
    const event = { workerId, isOnline, ts: Date.now() };
    if (wilayaCode) this.server.to(`wilaya:${wilayaCode}`).emit('worker:status', event);
    this.server.to(`worker:${workerId}`).emit('worker:status', event);
  }

  // ── Profile cache ────────────────────────────────────────────────────────────

  /**
   * Returns cached worker profile or fetches from MongoDB.
   * Avoids one DB round-trip per WebSocket reconnect (common on mobile).
   */
  private async getWorkerProfile(uid: string): Promise<CachedWorkerProfile> {
    const cached = this.profileCache.get(uid);
    if (cached && Date.now() - cached.cachedAt < PROFILE_CACHE_TTL_MS) {
      return cached;
    }

    const user = await this.userModel
      .findOne({ _id: uid, role: UserRole.Worker })
      .select('wilayaCode profession isOnline')
      .lean()
      .exec();

    const profile: CachedWorkerProfile = {
      isWorker:   !!user,
      wilayaCode: user ? (user as any).wilayaCode ?? undefined : undefined,
      profession: user ? (user as any).profession ?? undefined : undefined,
      cachedAt:   Date.now(),
    };

    // Only cache positive results for full TTL.
    // Cache negative results (non-workers) for 30s to reduce spam on
    // reconnecting clients, but allow role upgrade to propagate quickly.
    if (!user) {
      this.profileCache.set(uid, { ...profile, cachedAt: Date.now() - PROFILE_CACHE_TTL_MS + 30_000 });
    } else {
      this.profileCache.set(uid, profile);
    }

    return profile;
  }
}
