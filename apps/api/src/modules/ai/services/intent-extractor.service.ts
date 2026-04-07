import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { AiProvider } from '../interfaces/ai-provider.interface';
import { SearchIntent, VALID_PROFESSIONS, FALLBACK_INTENT } from '../interfaces/search-intent.interface';
import { QdrantService } from './qdrant.service';
import { AiRateLimitException } from '../exceptions/ai-provider.exception';
import type { Redis } from 'ioredis';

const SYSTEM_PROMPT = `You are an intent extractor for Khidmeti, an Algerian home services app.
Your ONLY job is to analyze the user's home problem description (which may be
in French, Arabic, Algerian Darija, or English, or any mix) and return a JSON object.

CRITICAL: Respond with ONLY raw JSON. No markdown, no code fences, no explanations.

LANGUAGE: Algerian Darija is the primary language — handle it natively without translation.
Understand expressions like "ماء ساقط", "الضوء طاح", "الكليماتيزور ما يبردش",
"صنفارية مسدودة", "الفريج خربان", "الباب ما يقفلش".

STT CORRECTION: Input may come from voice recognition and contain misrecognised words.
Infer the correct trade from context: "plan b" → plumber, "electric city" → electrician,
"clim ma tberdch" → ac_repair.

JSON schema (required, exact structure):
{
  "profession": "<string | null>",
  "is_urgent": <boolean>,
  "problem_description": "<string>",
  "max_radius_km": <number | null>,
  "confidence": <number>
}

Valid profession values — use EXACTLY one of these strings or null:
plumber, electrician, cleaner, painter, carpenter, gardener,
ac_repair, appliance_repair, mason, mechanic, mover

Rules:
- profession: the single most appropriate trade. null if unclear.
- is_urgent: true ONLY for genuine emergencies — flooding, complete power outage,
  gas leak, fire risk, broken lock at night. Default false.
- problem_description: concise factual English description, max 120 characters.
- max_radius_km: null unless user explicitly requests a distance.
- confidence: 0.0 to 1.0.`;

@Injectable()
export class IntentExtractorService {
  private readonly logger = new Logger(IntentExtractorService.name);

  // In-memory LRU cache for deduplication (up to 20 entries)
  private readonly cache    = new Map<string, SearchIntent>();
  private readonly MAX_CACHE = 20;

  // Redis rate-limit constants
  private readonly RATE_LIMIT_MAX    = 20;
  private readonly RATE_LIMIT_WINDOW = 3_600_000; // 1 hour in ms

  constructor(
    private readonly aiProvider: AiProvider,
    private readonly qdrant:     QdrantService,
    @Optional() @Inject('REDIS_CLIENT') private readonly redis?: Redis,
  ) {}

  // ────────────────────────────────────────────────────────────────────────────
  // Public API
  // ────────────────────────────────────────────────────────────────────────────

  async extractFromText(text: string, uid?: string): Promise<SearchIntent> {
    const trimmed = text.trim().slice(0, 2000);
    if (!trimmed) return { ...FALLBACK_INTENT };

    if (uid) await this.checkRateLimit(uid);

    const cacheKey = trimmed.toLowerCase();
    const cached   = this.cache.get(cacheKey);
    if (cached) return cached;

    try {
      // 1. Embed the query
      const embedding = await this.aiProvider.generateEmbedding(trimmed);

      // 2. Retrieve RAG examples from Qdrant
      const candidates = await this.qdrant.search('service_descriptions', embedding, 5);
      const context = candidates.length > 0
        ? 'Relevant examples:\n' +
          candidates
            .map((c) => c.payload['exampleText'] as string | undefined ?? '')
            .filter(Boolean)
            .join('\n')
        : '';

      const augmentedPrompt = context ? `${context}\n\nUser query: ${trimmed}` : trimmed;

      // 3. Call LLM
      const raw = await this.aiProvider.generateText(augmentedPrompt, SYSTEM_PROMPT, {
        temperature: 0.05,
        maxTokens:   300,
      });

      const intent = this.parseIntent(raw);

      // 4. Store in LRU cache
      if (this.cache.size >= this.MAX_CACHE) {
        const first = this.cache.keys().next().value as string;
        this.cache.delete(first);
      }
      this.cache.set(cacheKey, intent);

      return intent;
    } catch (err) {
      this.logger.error('IntentExtractorService.extractFromText failed', err);
      throw err;
    }
  }

  async extractFromAudio(
    audioBuffer: Buffer,
    mime: string,
    uid?: string,
  ): Promise<SearchIntent> {
    try {
      const { text, language } = await this.aiProvider.processAudio(audioBuffer, mime);
      if (!text.trim()) return { ...FALLBACK_INTENT };
      this.logger.debug(`Audio transcribed [${language}]: ${text}`);
      const intent = await this.extractFromText(text, uid);
      return { ...intent, transcribedText: text };
    } catch (err) {
      this.logger.error('IntentExtractorService.extractFromAudio failed', err);
      throw err;
    }
  }

  async extractFromImage(imageBase64: string, uid?: string): Promise<SearchIntent> {
    try {
      if (uid) await this.checkRateLimit(uid);
      const raw = await this.aiProvider.analyzeImage(
        imageBase64,
        'Analyze this image to identify the home maintenance problem. ' + SYSTEM_PROMPT,
        { temperature: 0.05, maxTokens: 300 },
      );
      return this.parseIntent(raw);
    } catch (err) {
      this.logger.error('IntentExtractorService.extractFromImage failed', err);
      throw err;
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Private helpers
  // ────────────────────────────────────────────────────────────────────────────

  private parseIntent(raw: string): SearchIntent {
    let s = raw.replace(/```json|```/g, '').trim();
    const start = s.indexOf('{');
    const end   = s.lastIndexOf('}');
    if (start === -1 || end === -1) return { ...FALLBACK_INTENT };

    s = s.slice(start, end + 1);
    try {
      const parsed = JSON.parse(s) as Partial<SearchIntent>;
      const profession =
        typeof parsed.profession === 'string' && VALID_PROFESSIONS.has(parsed.profession)
          ? parsed.profession
          : null;
      return {
        profession,
        is_urgent:           parsed.is_urgent === true,
        problem_description: (parsed.problem_description ?? '').slice(0, 120),
        max_radius_km:       typeof parsed.max_radius_km === 'number' ? parsed.max_radius_km : null,
        confidence:          typeof parsed.confidence === 'number'
          ? Math.min(1, Math.max(0, parsed.confidence))
          : 0.0,
      };
    } catch {
      return { ...FALLBACK_INTENT };
    }
  }

  /**
   * Redis sliding-window rate limiter.
   * Key: ai_rate:<uid> — sorted set of request timestamps.
   * Max 20 requests per sliding hour.
   * Gracefully degrades to no-op if Redis is unavailable.
   */
  private async checkRateLimit(uid: string): Promise<void> {
    if (!this.redis) return; // Redis optional — skip if not injected

    const key    = `ai_rate:${uid}`;
    const now    = Date.now();
    const cutoff = now - this.RATE_LIMIT_WINDOW;

    try {
      // Atomic pipeline: remove expired entries, count, add current
      const pipeline = this.redis.pipeline();
      pipeline.zremrangebyscore(key, '-inf', cutoff);
      pipeline.zcard(key);
      pipeline.zadd(key, now, `${now}`);
      pipeline.expire(key, 3600);

      const results = await pipeline.exec();
      const count   = (results?.[1]?.[1] as number) ?? 0;

      if (count >= this.RATE_LIMIT_MAX) {
        // Remove the entry we just added before throwing
        await this.redis.zrem(key, `${now}`);
        throw new AiRateLimitException();
      }
    } catch (err) {
      if (err instanceof AiRateLimitException) throw err;
      // Redis failure → allow request (non-blocking degradation)
      this.logger.warn(`Redis rate-limit check failed for ${uid}: ${err}`);
    }
  }
}
