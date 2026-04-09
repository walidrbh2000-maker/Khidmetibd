import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { QdrantClient } from '@qdrant/js-client-rest';

export const COLLECTION_WORKERS  = 'workers_vectors';
export const COLLECTION_REQUESTS = 'service_requests_vectors';
export const VECTOR_SIZE         = 768; // nomic-embed-text / text-embedding-004 dimension

/** Exponential backoff config */
const RETRY_ATTEMPTS = 8;
const RETRY_BASE_MS  = 500;  // 500ms → 1s → 2s → 4s … (caps at 30s)

@Injectable()
export class QdrantInitService implements OnModuleInit {
  private readonly logger = new Logger(QdrantInitService.name);
  private readonly client: QdrantClient;

  constructor(private readonly config: ConfigService) {
    this.client = new QdrantClient({
      url: this.config.getOrThrow<string>('QDRANT_URL'),
    });
  }

  get qdrantClient(): QdrantClient {
    return this.client;
  }

  /**
   * onModuleInit — retry with exponential backoff.
   * Qdrant container is healthy (port open) when the API starts, but
   * the HTTP layer may still be initialising its raft state machine.
   * Non-fatal: app boots even if Qdrant is temporarily unavailable;
   * the retry ensures collections are created before first use.
   */
  async onModuleInit(): Promise<void> {
    await this.retryUntilReady();
    await this.ensureCollection(COLLECTION_WORKERS);
    await this.ensureCollection(COLLECTION_REQUESTS);
  }

  // ── Private helpers ────────────────────────────────────────────────────

  private async retryUntilReady(): Promise<void> {
    for (let attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++) {
      try {
        const collections = await this.client.getCollections();
        this.logger.log(
          `✅ Qdrant reachable — ${collections.collections.length} collections found`,
        );
        return;
      } catch (err) {
        const delay = Math.min(RETRY_BASE_MS * 2 ** (attempt - 1), 30_000);
        this.logger.warn(
          `Qdrant not ready (attempt ${attempt}/${RETRY_ATTEMPTS}). ` +
          `Retrying in ${delay}ms… — ${(err as Error).message}`,
        );
        await this.sleep(delay);
      }
    }
    // Non-fatal: log error but don't crash the API bootstrap
    this.logger.error(
      'Qdrant unreachable after all retry attempts. ' +
      'Vector search will be unavailable until Qdrant recovers.',
    );
  }

  private async ensureCollection(name: string): Promise<void> {
    try {
      const existing = await this.client.getCollections();
      const found    = existing.collections.some((c) => c.name === name);

      if (!found) {
        await this.client.createCollection(name, {
          vectors: {
            size:     VECTOR_SIZE,
            distance: 'Cosine',
          },
          optimizers_config: { default_segment_number: 2 },
          replication_factor: 1,
        });
        this.logger.log(`Qdrant collection created: ${name}`);
      } else {
        this.logger.debug(`Qdrant collection already exists: ${name}`);
      }
    } catch (err) {
      this.logger.error(`Failed to ensure Qdrant collection "${name}"`, err);
      // Non-fatal: retry on next cold start
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  // ── Public upsert / search helpers (used by matching service) ──────────

  async upsertWorkerVector(
    workerId: string,
    vector:   number[],
    payload:  Record<string, unknown>,
  ): Promise<void> {
    await this.client.upsert(COLLECTION_WORKERS, {
      wait:   true,
      points: [{ id: workerId, vector, payload }],
    });
  }

  async upsertRequestVector(
    requestId: string,
    vector:    number[],
    payload:   Record<string, unknown>,
  ): Promise<void> {
    await this.client.upsert(COLLECTION_REQUESTS, {
      wait:   true,
      points: [{ id: requestId, vector, payload }],
    });
  }

  async searchWorkers(
    vector: number[],
    filter: Record<string, unknown>,
    limit   = 20,
  ) {
    return this.client.search(COLLECTION_WORKERS, {
      vector,
      filter,
      limit,
      with_payload: true,
    });
  }

  async searchRequests(
    vector: number[],
    filter: Record<string, unknown>,
    limit   = 20,
  ) {
    return this.client.search(COLLECTION_REQUESTS, {
      vector,
      filter,
      limit,
      with_payload: true,
    });
  }

  async deleteWorkerVector(workerId: string): Promise<void> {
    await this.client.delete(COLLECTION_WORKERS, {
      wait:   true,
      points: [workerId],
    });
  }

  async deleteRequestVector(requestId: string): Promise<void> {
    await this.client.delete(COLLECTION_REQUESTS, {
      wait:   true,
      points: [requestId],
    });
  }
}
