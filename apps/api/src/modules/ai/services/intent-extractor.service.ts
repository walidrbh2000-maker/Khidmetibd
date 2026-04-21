// apps/api/src/modules/ai/services/intent-extractor.service.ts

import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { createHash }                           from 'crypto';
import type { IAiProvider, AudioResult }        from '../interfaces/ai-provider.interface';
import { AI_PROVIDER_TOKEN }                    from '../interfaces/ai-provider.interface';
import { AiRateLimitException, AiProviderException } from '../exceptions/ai-provider.exception';
import { HttpStatus }                           from '@nestjs/common';
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

// ── Error classification ───────────────────────────────────────────────────────
//
// QUOTA    (HTTP 429) — hard rate-limit.
// OVERLOAD (HTTP 503) — transient; the caller should retry after back-off.
//
// FIX v6 : ajout des patterns Ollama OOM dans OVERLOAD_PATTERNS.
//   AVANT : l'erreur "requires more system memory (4.9 GiB)" tombait dans
//           le bloc catch générique → return { ...FALLBACK } silencieux →
//           confidence=0 affiché dans l'UI sans aucun message d'erreur.
//   APRÈS : classifiée comme 503 SERVICE_UNAVAILABLE → Flutter reçoit un
//           message clair et peut proposer une nouvelle tentative.

/** Patterns indicating a hard quota / rate-limit → HTTP 429 */
const QUOTA_PATTERNS: RegExp[] = [
  /quota/i,
  /resource.?exhausted/i,
  /rate.?limit/i,
  /all ai providers exhausted/i,
  /429/,
];

/**
 * Patterns indicating a transient overload / unavailability → HTTP 503.
 *
 * FIX v6 — ajout des patterns Ollama OOM :
 *   - "message requires more system memory" : Ollama ne peut pas charger le modèle
 *   - "not enough.*memory" : formulation générique mémoire insuffisante
 *   Ces erreurs sont transitoires : elles se résolvent seules une fois que
 *   Ollama récupère de la mémoire (ex: après garbage collection ou redémarrage).
 */
const OVERLOAD_PATTERNS: RegExp[] = [
  /503/,
  /unavailable/i,
  /high demand/i,
  /model.*overload/i,
  /temporarily.*unavailable/i,
  /please try again later/i,
  /requires more system memory/i,  // FIX v6 : Ollama OOM — "requires more system memory (4.9 GiB)"
  /not enough.*memory/i,           // FIX v6 : formulation générique mémoire insuffisante
];

function isQuotaError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return QUOTA_PATTERNS.some((p) => p.test(msg));
}

function isOverloadError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return !isQuotaError(err) && OVERLOAD_PATTERNS.some((p) => p.test(msg));
}

// ── Garbage transcript detection ───────────────────────────────────────────────

const TIMESTAMP_ONLY_RE = /^(?:\d{1,2}:\d{2}\s*)+$/;

function isGarbageTranscript(text: string): boolean {
  const t = text.trim();
  if (t.length < 3)              return true;
  if (TIMESTAMP_ONLY_RE.test(t)) return true;
  if (/^[\d\s:.,\-]+$/.test(t)) return true;
  return false;
}

// ── System prompt ──────────────────────────────────────────────────────────────

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

  private readonly cache       = new Map<string, SearchIntent>();
  private readonly MAX_CACHE   = 100;
  private readonly RATE_LIMIT_MAX    = 20;
  private readonly RATE_LIMIT_WINDOW = 3_600_000;

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
      if (isQuotaError(err)) {
        this.logger.warn(`AI quota/rate-limit on text extraction: ${(err as Error).message}`);
        throw new AiRateLimitException();
      }
      if (isOverloadError(err)) {
        this.logger.warn(`AI model overloaded on text extraction: ${(err as Error).message}`);
        throw new AiProviderException(
          'AI model temporarily overloaded. Please try again later.',
          HttpStatus.SERVICE_UNAVAILABLE,
        );
      }
      this.logger.error(`extractFromText failed: ${(err as Error).message}`);
      return { ...FALLBACK };
    }
  }

  async extractFromAudio(buffer: Buffer, mime: string, uid?: string): Promise<SearchIntent> {
    let transcription: AudioResult;

    try {
      transcription = await this.ai.processAudio(buffer, mime);
    } catch (err) {
      if (isQuotaError(err)) {
        this.logger.warn(`AI quota/rate-limit on audio: ${(err as Error).message}`);
        throw new AiRateLimitException();
      }
      if (isOverloadError(err)) {
        this.logger.warn(`AI model overloaded on audio: ${(err as Error).message}`);
        throw new AiProviderException(
          'AI model temporarily overloaded. Please try again later.',
          HttpStatus.SERVICE_UNAVAILABLE,
        );
      }
      this.logger.error(`Audio processing failed: ${(err as Error).message}`);
      return { ...FALLBACK };
    }

    const { text, language } = transcription;

    if (!text.trim() || isGarbageTranscript(text)) {
      this.logger.debug(
        `Audio produced unusable transcript (language=${language}): ` +
        `"${text.trim().slice(0, 60)}" — returning FALLBACK`,
      );
      return { ...FALLBACK };
    }

    this.logger.debug(`Audio transcribed [${language}]: ${text.slice(0, 80)}`);

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
        this.logger.warn(`AI quota/rate-limit on image: ${(err as Error).message}`);
        throw new AiRateLimitException();
      }
      if (isOverloadError(err)) {
        this.logger.warn(`AI model overloaded on image: ${(err as Error).message}`);
        throw new AiProviderException(
          'AI model temporarily overloaded. Please try again later.',
          HttpStatus.SERVICE_UNAVAILABLE,
        );
      }
      this.logger.error(`extractFromImage failed: ${(err as Error).message}`);
      return { ...FALLBACK };
    }
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  private parse(raw: string): SearchIntent {
    const s = raw.replace(/```json|```/g, '').trim();
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

  private hashKey(text: string): string {
    return createHash('sha256').update(text).digest('hex').slice(0, 16);
  }

  private setCache(key: string, intent: SearchIntent): void {
    if (this.cache.size >= this.MAX_CACHE) {
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
