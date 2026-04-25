// apps/api/src/modules/ai/services/intent-extractor.service.ts
//
// v14.3 — CORRECTIF CRITIQUE : réduction du SYSTEM_PROMPT
//
// PROBLÈME v14.0-14.2 :
//   SYSTEM_PROMPT contenait ~1925 tokens (14 exemples few-shot + mappings Darija).
//   Prefill CPU Gemma4 E2B : ~4-8 tok/s → 1925 tokens = 240-480 secondes.
//   Timeout 90s → circuit breaker s'ouvre après 3 requêtes. RIEN ne fonctionne.
//
// FIX v14.3 :
//   SYSTEM_PROMPT réduit à ~150 tokens (réduction 92%).
//   Gemma4 est un modèle multilingue puissant — il comprend le Darija nativement.
//   Il n'a pas besoin de 14 exemples : 3 suffisent pour ancrer le format JSON.
//   Prefill estimé : 150 tok / 8 tok/s = ~19 secondes. Génération : ~12 secondes.
//   Total : ~31 secondes. Largement dans les 90s (et bien dans les 180s du .env v14.3).
//
// AUTRES FIX v14.3 :
//   maxTokens: 512 → 128 (JSON ~50 tokens max — réduit le temps de génération)

import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { createHash }                           from 'crypto';
import type { IAiProvider, AudioResult }        from '../interfaces/ai-provider.interface';
import { AI_PROVIDER_TOKEN }                    from '../interfaces/ai-provider.interface';
import { AiRateLimitException, AiProviderException } from '../exceptions/ai-provider.exception';
import { HttpStatus }                           from '@nestjs/common';
import type { Redis }                           from 'ioredis';

// ── Types publics ──────────────────────────────────────────────────────────────

export interface SearchIntent {
  profession:          string | null;
  is_urgent:           boolean;
  problem_description: string;
  max_radius_km:       number | null;
  confidence:          number;
  transcribedText?:    string;
}

// ── Constantes ─────────────────────────────────────────────────────────────────

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

// ── Classification des erreurs ─────────────────────────────────────────────────

const QUOTA_PATTERNS: RegExp[] = [
  /quota/i, /resource.?exhausted/i, /rate.?limit/i, /429/,
];

const OVERLOAD_PATTERNS: RegExp[] = [
  /503/, /unavailable/i, /high demand/i, /model.*overload/i,
  /temporarily.*unavailable/i, /fetch failed/i,
  /gemma4 fetch failed/i, /econnrefused/i, /econnreset/i,
  /socket hang up/i, /network.*error/i, /timeout/i,
  /empty or null content/i, /introuvable/i,
  /audio non support/i,
];

function isQuotaError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return QUOTA_PATTERNS.some((p) => p.test(msg));
}

function isOverloadError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return !isQuotaError(err) && OVERLOAD_PATTERNS.some((p) => p.test(msg));
}

// ── Détection réponses parasites ───────────────────────────────────────────────

const GARBAGE_RE = /^(?:\[\d{1,2}:\d{2}(?:\.\d+)?\s*→?\s*\d{0,2}:?\d{0,2}(?:\.\d+)?\]\s*)+$/;

function isGarbageResponse(text: string): boolean {
  const t = text.trim();
  if (t.length < 3)               return true;
  if (GARBAGE_RE.test(t))         return true;
  if (/^[\d\s:.,\-\[\]→]+$/.test(t)) return true;
  return false;
}

// ══════════════════════════════════════════════════════════════════════════════
// CIRCUIT BREAKER PAR MODALITÉ
// ══════════════════════════════════════════════════════════════════════════════

type CircuitState = 'closed' | 'open' | 'half-open';

class CircuitBreaker {
  private state:        CircuitState = 'closed';
  private failures      = 0;
  private lastFailureAt = 0;

  constructor(
    private readonly name:      string,
    private readonly threshold: number,
    private readonly resetMs:   number,
    private readonly logger:    Logger,
  ) {}

  assertClosed(): void {
    if (this.state === 'closed') return;

    if (this.state === 'open') {
      const elapsed = Date.now() - this.lastFailureAt;
      if (elapsed >= this.resetMs) {
        this.state = 'half-open';
        this.logger.log(`Circuit [${this.name}] → HALF-OPEN (${(elapsed / 1000).toFixed(0)}s écoulé)`);
        return;
      }
      const remaining = Math.ceil((this.resetMs - elapsed) / 1000);
      this.logger.warn(`Circuit [${this.name}] OPEN — fast-fail. Récupération dans ~${remaining}s`);
      throw new AiProviderException(
        `Service IA temporairement indisponible. Réessayez dans ${remaining} secondes.`,
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
    // half-open : laisser passer une requête test
  }

  onSuccess(): void {
    if (this.state !== 'closed') {
      this.logger.log(`Circuit [${this.name}] → CLOSED (récupéré après ${this.failures} échec(s))`);
    }
    this.failures = 0;
    this.state    = 'closed';
  }

  onFailure(): void {
    this.failures++;
    this.lastFailureAt = Date.now();
    if (this.failures >= this.threshold && this.state !== 'open') {
      this.state = 'open';
      this.logger.warn(
        `Circuit [${this.name}] → OPEN après ${this.failures} échecs consécutifs. ` +
        `Fast-fail pour ${this.resetMs / 1000}s.`,
      );
    }
  }

  getStatus() {
    return {
      name:          this.name,
      state:         this.state,
      failures:      this.failures,
      lastFailureAt: this.lastFailureAt,
      recoversAt:    this.state === 'open' ? this.lastFailureAt + this.resetMs : null,
    };
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SYSTEM PROMPT — v14.3 : MINIMAL (~150 tokens)
//
// AVANT v14.3 : ~1925 tokens (14 exemples few-shot + mappings Darija complets)
//   → Prefill CPU : 240-480 secondes → TIMEOUT systématique
//
// APRÈS v14.3 : ~150 tokens (3 exemples + règles essentielles)
//   → Prefill CPU estimé : ~19 secondes → FONCTIONNE dans 90s
//
// PRINCIPE : Gemma4 est un modèle multilingue puissant (Google Gemma 4E).
//   Il comprend le Darija algérien nativement — pas besoin de tous les mapper.
//   Les 3 exemples JSON ancrent le format de sortie. Les règles couvrent l'essentiel.
//   Moins de tokens = plus rapide = pas de timeout.
// ══════════════════════════════════════════════════════════════════════════════

const SYSTEM_PROMPT = `\
You are a home-service intent extractor for Khidmeti (Algeria).
Analyze text in Algerian Darija, French, Arabic, or any mix.

Reply ONLY with valid JSON on one line — no markdown, no explanation, nothing else:
{"profession":<string|null>,"is_urgent":<bool>,"problem_description":<string>,"max_radius_km":<number|null>,"confidence":<number>}

profession (exact value or null): plumber|electrician|cleaner|painter|carpenter|gardener|ac_repair|appliance_repair|mason|mechanic|mover
is_urgent=true ONLY: active flooding / total power outage / gas leak / locked door at night
problem_description: factual English, max 100 chars
confidence: 0.0–1.0 (0.0 if profession unknown, never null)

Examples:
"عندي ماء ساقط من السقف"→{"profession":"plumber","is_urgent":false,"problem_description":"water leaking from ceiling","max_radius_km":null,"confidence":0.95}
"الكليمو ما يبردش"→{"profession":"ac_repair","is_urgent":false,"problem_description":"AC not cooling","max_radius_km":null,"confidence":0.96}
"الضو طاح كامل وعاجل"→{"profession":"electrician","is_urgent":true,"problem_description":"total power outage urgent","max_radius_km":null,"confidence":0.98}
`;

// ══════════════════════════════════════════════════════════════════════════════
// SERVICE PRINCIPAL
// ══════════════════════════════════════════════════════════════════════════════

@Injectable()
export class IntentExtractorService {
  private readonly logger = new Logger(IntentExtractorService.name);

  // ── Cache en mémoire (LRU simple) ─────────────────────────────────────────
  private readonly cache     = new Map<string, SearchIntent>();
  private readonly MAX_CACHE = 200;

  // ── Rate limiting ──────────────────────────────────────────────────────────
  private readonly RATE_LIMIT_MAX    = 20;
  private readonly RATE_LIMIT_WINDOW = 3_600_000; // 1h en ms

  // ── Circuit breakers (2 circuits isolés par modalité) ─────────────────────
  private readonly circuitGemma4: CircuitBreaker;
  private readonly circuitAudio:  CircuitBreaker;

  private static readonly CB_THRESHOLD = 3;
  private static readonly CB_RESET_MS  = 30_000;

  constructor(
    @Inject(AI_PROVIDER_TOKEN)
    private readonly ai: IAiProvider,
    @Optional() @Inject('REDIS_CLIENT')
    private readonly redis?: Redis,
  ) {
    this.circuitGemma4 = new CircuitBreaker('gemma4', IntentExtractorService.CB_THRESHOLD, IntentExtractorService.CB_RESET_MS, this.logger);
    this.circuitAudio  = new CircuitBreaker('audio',  IntentExtractorService.CB_THRESHOLD, IntentExtractorService.CB_RESET_MS, this.logger);
  }

  // ── API publique ────────────────────────────────────────────────────────────

  /** Extraction d'intention depuis un texte (Darija / FR / AR / mix) */
  async extractFromText(text: string, uid?: string): Promise<SearchIntent> {
    const trimmed = text.trim().slice(0, 4000);
    if (!trimmed) return { ...FALLBACK };

    if (uid) await this.checkRateLimit(uid);

    this.circuitGemma4.assertClosed();

    const cacheKey = this.hashKey(trimmed.toLowerCase());
    const cached   = this.cache.get(cacheKey);
    if (cached) {
      this.logger.debug(`Cache hit — key=${cacheKey.slice(0, 8)}`);
      return { ...cached };
    }

    try {
      // v14.3 : maxTokens 512 → 128 (JSON ~50 tokens max)
      const raw    = await this.ai.generateText(trimmed, SYSTEM_PROMPT, { temperature: 0.05, maxTokens: 128 });
      const intent = this.parseIntent(raw);
      this.circuitGemma4.onSuccess();
      this.setCache(cacheKey, intent);
      return intent;
    } catch (err) {
      return this.handleError(err, 'text', this.circuitGemma4);
    }
  }

  /**
   * Extraction depuis un audio.
   * v14 — Pipeline single-step via Gemma4 audio natif (llama.cpp PR#21421)
   * v14.3 — L'audio est transcodé en WAV 16kHz mono par gemma4.strategy.ts
   *          avant envoi à llama.cpp (fix erreur 400 format m4a/ogg/etc.)
   */
  async extractFromAudio(buffer: Buffer, mime: string, uid?: string): Promise<SearchIntent> {
    this.circuitAudio.assertClosed();

    let audioResult: AudioResult;
    try {
      audioResult = await this.ai.processAudio(buffer, mime);
      this.circuitAudio.onSuccess();
    } catch (err) {
      return this.handleError(err, 'audio', this.circuitAudio);
    }

    const { text } = audioResult;

    if (!text.trim() || isGarbageResponse(text)) {
      this.logger.debug(`Audio: réponse Gemma4 vide ou parasite → FALLBACK`);
      return { ...FALLBACK };
    }

    const intent = this.parseIntent(text);

    this.logger.debug(
      `Audio intent — profession=${intent.profession ?? 'null'} ` +
      `urgent=${intent.is_urgent} confidence=${intent.confidence}`,
    );

    return intent;
  }

  /**
   * Extraction depuis une image.
   * Pipeline v14 (inchangé) : Gemma4 single-step (image + texte → JSON)
   * v14.3 : maxTokens 512 → 128
   */
  async extractFromImage(imageBase64: string, uid?: string): Promise<SearchIntent> {
    if (uid) await this.checkRateLimit(uid);

    this.circuitGemma4.assertClosed();

    try {
      // v14.3 : maxTokens 512 → 128 (JSON ~50 tokens max)
      const raw = await this.ai.analyzeImage(
        imageBase64,
        SYSTEM_PROMPT,
        { temperature: 0.05, maxTokens: 128 },
      );
      this.circuitGemma4.onSuccess();
      return this.parseIntent(raw);
    } catch (err) {
      return this.handleError(err, 'image', this.circuitGemma4);
    }
  }

  /** État des circuit breakers (pour health check) */
  getAllCircuitStatuses() {
    return {
      gemma4: this.circuitGemma4.getStatus(),
      audio:  this.circuitAudio.getStatus(),
    };
  }

  // ── Gestion d'erreurs centralisée ──────────────────────────────────────────

  private handleError(
    err:     unknown,
    context: string,
    circuit: CircuitBreaker,
  ): never | SearchIntent {
    circuit.onFailure();

    const msg = err instanceof Error ? err.message : String(err);

    if (isQuotaError(err)) {
      this.logger.warn(`Rate-limit [${context}]: ${msg}`);
      throw new AiRateLimitException();
    }

    if (isOverloadError(err)) {
      this.logger.warn(`Overload/unavailable [${context}]: ${msg}`);
      throw new AiProviderException(
        `Service IA ${context} temporairement indisponible. Réessayez dans quelques secondes.`,
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    this.logger.error(`[${context}] Erreur non classifiée: ${msg}`, (err as Error).stack);
    return { ...FALLBACK };
  }

  // ── Parsing JSON ───────────────────────────────────────────────────────────

  private parseIntent(raw: string): SearchIntent {
    const cleaned = raw
      .replace(/<\|think\|>[\s\S]*?<\|\/think\|>/gi, '')
      .replace(/<think>[\s\S]*?<\/think>/gi, '')
      .replace(/```(?:json)?\s*/g, '')
      .replace(/```/g, '')
      .trim();

    const start = cleaned.indexOf('{');
    const end   = cleaned.lastIndexOf('}');

    if (start === -1 || end === -1 || start >= end) {
      this.logger.warn(`Pas de JSON dans la réponse : "${cleaned.slice(0, 120)}"`);
      return { ...FALLBACK };
    }

    try {
      const p = JSON.parse(cleaned.slice(start, end + 1)) as Partial<SearchIntent>;

      return {
        profession: (
          typeof p.profession === 'string' && VALID_PROFESSIONS.has(p.profession)
            ? p.profession
            : null
        ),
        is_urgent: p.is_urgent === true,
        problem_description: typeof p.problem_description === 'string'
          ? p.problem_description.slice(0, 120)
          : '',
        max_radius_km: typeof p.max_radius_km === 'number' && p.max_radius_km > 0
          ? p.max_radius_km
          : null,
        confidence: typeof p.confidence === 'number'
          ? Math.min(1, Math.max(0, p.confidence))
          : 0,
      };
    } catch (e) {
      this.logger.warn(`JSON parse échoué : ${(e as Error).message} — raw="${cleaned.slice(0, 80)}"`);
      return { ...FALLBACK };
    }
  }

  // ── Cache ──────────────────────────────────────────────────────────────────

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

  // ── Rate limiting Redis ────────────────────────────────────────────────────

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
      if ((e as Error).constructor?.name === 'AiRateLimitException') throw e;
      this.logger.warn(`Redis rate-limit dégradé: ${(e as Error).message}`);
    }
  }
}
