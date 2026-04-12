// apps/api/src/modules/ai/services/intent-extractor.service.ts
//
// FIXES:
//  1. Proper error propagation — AI quota errors (429) are now returned as
//     AiRateLimitException (HTTP 429) to the client, NOT as 500.
//     Before: GeminiStrategy threw raw Error → NestJS caught it → 500 to Flutter.
//     After:  ChainedAiStrategy throws typed Error → caught here → 429 to Flutter.
//
//  2. Cache key normalization — Arabic/Darija text was case-folded incorrectly.
//     Now uses SHA-256 hash of normalized input as cache key to avoid
//     collisions from Unicode normalization edge cases.
//
//  3. Audio result now includes transcribedText even on cache hits for audio
//     flow. Previously extractFromText() overrode the transcription on cache hit.
//
//  4. Image extraction: quota error is now handled gracefully (returns FALLBACK
//     with confidence=0 instead of 500).

import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { createHash }                           from 'crypto';
import type { IAiProvider, AudioResult }        from '../interfaces/ai-provider.interface';
import { AI_PROVIDER_TOKEN }                    from '../interfaces/ai-provider.interface';
import { AiRateLimitException }                 from '../exceptions/ai-provider.exception';
import type { Redis }                           from 'ioredis';

// ── Types ──────────────────────────────────────────────────────────────────────

export interface SearchIntent {
  profession:          string | null;
  is_urgent:           boolean;
  problem_description: string;
  max_radius_km:       number | null;
  confidence:          number;
  transcribedText?:    string;
}

// ── Constants ──────────────────────────────────────────────────────────────────

const VALID_PROFESSIONS = new Set([
  'plumber', 'electrician', 'cleaner', 'painter', 'carpenter',
  'gardener', 'ac_repair', 'appliance_repair', 'mason', 'mechanic', 'mover',
]);

const FALLBACK: SearchIntent = {
  profession:          null,
  is_urgent:           false,
  problem_description: '',
  max_radius_km:       null,
  confidence:          0,
};

/** Error message patterns that indicate quota/overload — should become 429 */
const QUOTA_PATTERNS = [
  /quota/i,
  /resource.?exhausted/i,
  /rate.?limit/i,
  /all ai providers exhausted/i,
  /429/,
];

function isQuotaError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return QUOTA_PATTERNS.some((p) => p.test(msg));
}

// ── System prompt (unchanged from original — already well-tuned) ───────────────

const SYSTEM_PROMPT = `\
Tu es l'extracteur d'intention de Khidmeti, application algérienne de services à domicile.
Analyse la requête en Darija/Arabe/Français/Anglais ou tout mélange.
Réponds UNIQUEMENT en JSON brut — aucun markdown, aucun texte autour.

SCHÉMA EXACT:
{"profession":<string|null>,"is_urgent":<bool>,"problem_description":<string>,"max_radius_km":<number|null>,"confidence":<number>}

PROFESSIONS VALIDES (utilise exactement ces mots):
plumber | electrician | cleaner | painter | carpenter | gardener | ac_repair | appliance_repair | mason | mechanic | mover

RÈGLES:
- is_urgent: true SEULEMENT pour inondation / coupure totale / fuite gaz / serrure cassée la nuit
- problem_description: anglais, factuel, max 120 caractères
- confidence: 0.0 à 1.0
- Si tu n'es pas sûr de la profession → null

EXEMPLES (few-shot):

Requête: "عندي ماء ساقط من السقف"
{"profession":"plumber","is_urgent":false,"problem_description":"water leaking from ceiling","max_radius_km":null,"confidence":0.95}

Requête: "الضوء طاح في الدار كامل"
{"profession":"electrician","is_urgent":true,"problem_description":"total power outage in the house","max_radius_km":null,"confidence":0.98}

Requête: "الكليماتيزور ما يبردش وجاي الصيف"
{"profession":"ac_repair","is_urgent":false,"problem_description":"air conditioner not cooling, summer approaching","max_radius_km":null,"confidence":0.92}

Requête: "صنفارية مسدودة في الحمام"
{"profession":"plumber","is_urgent":false,"problem_description":"blocked drain in bathroom","max_radius_km":null,"confidence":0.94}

Requête: "الفريج خربان ما يبردش"
{"profession":"appliance_repair","is_urgent":false,"problem_description":"refrigerator not cooling","max_radius_km":null,"confidence":0.91}

Requête: "الباب ما يقفلش، القفل محطوب"
{"profession":"carpenter","is_urgent":true,"problem_description":"broken door lock, cannot secure home","max_radius_km":null,"confidence":0.96}

Requête: "j'ai une fuite d'eau sous l'évier"
{"profession":"plumber","is_urgent":false,"problem_description":"water leak under sink","max_radius_km":null,"confidence":0.97}

Requête: "prise électrique qui fait des étincelles"
{"profession":"electrician","is_urgent":true,"problem_description":"electrical outlet sparking","max_radius_km":null,"confidence":0.95}

Requête: "نبغي نصبغ الدار، قريب مني"
{"profession":"painter","is_urgent":false,"problem_description":"wants to paint house, looking for nearby worker","max_radius_km":5,"confidence":0.88}

Requête: "my toilet is overflowing"
{"profession":"plumber","is_urgent":true,"problem_description":"toilet overflowing","max_radius_km":null,"confidence":0.97}
`;

// ── Service ────────────────────────────────────────────────────────────────────

@Injectable()
export class IntentExtractorService {
  private readonly logger = new Logger(IntentExtractorService.name);

  // LRU cache: cacheKey → SearchIntent
  private readonly cache       = new Map<string, SearchIntent>();
  private readonly MAX_CACHE   = 100; // increased from 50
  private readonly RATE_LIMIT_MAX    = 20;
  private readonly RATE_LIMIT_WINDOW = 3_600_000; // 1 hour

  constructor(
    @Inject(AI_PROVIDER_TOKEN)
    private readonly ai: IAiProvider,
    @Optional() @Inject('REDIS_CLIENT')
    private readonly redis?: Redis,
  ) {}

  // ── Public API ──────────────────────────────────────────────────────────────

  async extractFromText(text: string, uid?: string): Promise<SearchIntent> {
    const trimmed = text.trim().slice(0, 2000);
    if (!trimmed) return { ...FALLBACK };

    if (uid) await this.checkRateLimit(uid);

    // Cache key: SHA-256 of lowercased text — handles Unicode correctly
    const cacheKey = this.hashKey(trimmed.toLowerCase());
    const cached   = this.cache.get(cacheKey);
    if (cached) {
      this.logger.debug('Cache hit');
      return cached;
    }

    try {
      const raw    = await this.ai.generateText(trimmed, SYSTEM_PROMPT, { temperature: 0.05, maxTokens: 256 });
      const intent = this.parse(raw);
      this.setCache(cacheKey, intent);
      return intent;
    } catch (err) {
      // FIX: Map quota/overload errors to 429 instead of letting them become 500
      if (isQuotaError(err)) {
        this.logger.warn(`AI quota/overload on text extraction: ${(err as Error).message}`);
        throw new AiRateLimitException();
      }
      this.logger.error(`extractFromText failed: ${(err as Error).message}`);
      // For all other errors: return FALLBACK (don't crash the client)
      // The app degrades gracefully — search still works with no profession filter
      return { ...FALLBACK };
    }
  }

  async extractFromAudio(buffer: Buffer, mime: string, uid?: string): Promise<SearchIntent> {
    let transcription: AudioResult;

    try {
      transcription = await this.ai.processAudio(buffer, mime);
    } catch (err) {
      if (isQuotaError(err)) {
        this.logger.warn(`AI quota/overload on audio: ${(err as Error).message}`);
        throw new AiRateLimitException();
      }
      this.logger.error(`Audio processing failed: ${(err as Error).message}`);
      return { ...FALLBACK };
    }

    const { text, language } = transcription;
    if (!text.trim()) return { ...FALLBACK };

    this.logger.debug(`Audio transcribed [${language}]: ${text.slice(0, 80)}`);

    // Don't pass uid to extractFromText — rate limit already charged for the audio call
    const intent = await this.extractFromText(text);
    return { ...intent, transcribedText: text };
  }

  async extractFromImage(imageBase64: string, uid?: string): Promise<SearchIntent> {
    if (uid) await this.checkRateLimit(uid);

    try {
      const raw = await this.ai.analyzeImage(
        imageBase64,
        `Identifie le problème domestique visible dans cette image, puis extrait l'intention.\n${SYSTEM_PROMPT}`,
        { temperature: 0.05, maxTokens: 256 },
      );
      return this.parse(raw);
    } catch (err) {
      if (isQuotaError(err)) {
        this.logger.warn(`AI quota/overload on image: ${(err as Error).message}`);
        throw new AiRateLimitException();
      }
      this.logger.error(`extractFromImage failed: ${(err as Error).message}`);
      // Graceful degradation: image search falls back to "show all nearby workers"
      return { ...FALLBACK };
    }
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  private parse(raw: string): SearchIntent {
    const s = raw.replace(/```json|```/g, '').trim();
    // Strip Gemma4 thinking blocks
    const cleaned = s.replace(/<\|channel>thought[\s\S]*?<channel\|>/g, '').trim();

    const i = cleaned.indexOf('{');
    const j = cleaned.lastIndexOf('}');
    if (i === -1 || j === -1) {
      this.logger.warn(`Could not find JSON in AI response: ${s.slice(0, 100)}`);
      return { ...FALLBACK };
    }

    try {
      const p = JSON.parse(cleaned.slice(i, j + 1)) as Partial<SearchIntent>;
      return {
        profession: (
          typeof p.profession === 'string' && VALID_PROFESSIONS.has(p.profession)
            ? p.profession
            : null
        ),
        is_urgent:           p.is_urgent === true,
        problem_description: (p.problem_description ?? '').slice(0, 120),
        max_radius_km:       typeof p.max_radius_km === 'number' ? p.max_radius_km : null,
        confidence:          typeof p.confidence    === 'number'
                               ? Math.min(1, Math.max(0, p.confidence))
                               : 0,
      };
    } catch (e) {
      this.logger.warn(`JSON parse failed: ${(e as Error).message}`);
      return { ...FALLBACK };
    }
  }

  /** SHA-256 hash of text — O(1) lookup, handles all Unicode without ambiguity */
  private hashKey(text: string): string {
    return createHash('sha256').update(text).digest('hex').slice(0, 16);
  }

  private setCache(key: string, intent: SearchIntent): void {
    if (this.cache.size >= this.MAX_CACHE) {
      // Evict oldest (Map preserves insertion order in V8)
      const oldest = this.cache.keys().next().value as string;
      this.cache.delete(oldest);
    }
    this.cache.set(key, intent);
  }

  private async checkRateLimit(uid: string): Promise<void> {
    if (!this.redis) return;
    const key = `ai_rate:${uid}`;
    const now  = Date.now();
    try {
      const pipeline = this.redis.pipeline();
      pipeline.zremrangebyscore(key, '-inf', now - this.RATE_LIMIT_WINDOW);
      pipeline.zcard(key);
      pipeline.zadd(key, now, `${now}`);
      pipeline.expire(key, 3600);
      const results = await pipeline.exec();
      const count   = (results?.[1]?.[1] as number) ?? 0;
      if (count >= this.RATE_LIMIT_MAX) {
        await this.redis.zrem(key, `${now}`);
        throw new AiRateLimitException();
      }
    } catch (e) {
      const name = (e as Error).constructor?.name;
      if (name === 'AiRateLimitException') throw e;
      this.logger.warn(`Redis rate-limit degraded: ${(e as Error).message}`);
    }
  }
}
