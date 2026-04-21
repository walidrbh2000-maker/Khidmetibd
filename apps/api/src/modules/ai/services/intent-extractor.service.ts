// apps/api/src/modules/ai/services/intent-extractor.service.ts
//
// FIX v9 — Per-modality circuit breakers
//
// ══════════════════════════════════════════════════════════════════════════════
// PROBLÈME (observé dans les logs) :
//
//   "AI circuit breaker OPEN - rejecting [audio] request. Recovery in ~3s"
//
//   CAUSE : Un seul circuit breaker partagé entre text / audio / image.
//           Quand moondream timeout 3 fois (image), le circuit s'ouvre et
//           BLOQUE toutes les requêtes audio et texte également.
//
//   CONSÉQUENCE UTILISATEUR :
//     1. Utilisateur envoie une photo → timeout moondream (3 fois) → CB OPEN
//     2. Utilisateur essaie le micro → "circuit breaker OPEN" → BLOQUÉ ❌
//     3. Utilisateur essaie le texte → "circuit breaker OPEN" → BLOQUÉ ❌
//
// FIX v9 — Trois circuit breakers indépendants (un par modalité) :
//
//   circuitText  : géré par extractFromText
//   circuitAudio : géré par extractFromAudio
//   circuitImage : géré par extractFromImage
//
//   → Les timeouts moondream n'impactent PLUS le texte ni l'audio.
//   → Chaque modalité récupère indépendamment.
//
// ══════════════════════════════════════════════════════════════════════════════
// Comportement du circuit breaker (inchangé, maintenant par modalité) :
//
//   CLOSED    → opération normale
//   OPEN      → fast-fail immédiat avec 503
//   HALF-OPEN → laisse passer une requête test
//
//   Paramètres : CIRCUIT_THRESHOLD=3 échecs / CIRCUIT_RESET_MS=30s
// ══════════════════════════════════════════════════════════════════════════════

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

const QUOTA_PATTERNS: RegExp[] = [
  /quota/i,
  /resource.?exhausted/i,
  /rate.?limit/i,
  /all ai providers exhausted/i,
  /429/,
];

// Overload patterns — incluent maintenant le message de timeout clair de FIX v9
const OVERLOAD_PATTERNS: RegExp[] = [
  /503/,
  /unavailable/i,
  /high demand/i,
  /model.*overload/i,
  /temporarily.*unavailable/i,
  /please try again later/i,
  /requires more system memory/i,
  /not enough.*memory/i,
  /runner process has terminated/i,
  /llama runner/i,
  /empty or null content/i,
  /fetch failed/i,
  /ollama fetch failed/i,
  /whisper fetch failed/i,
  /econnrefused/i,
  /econnreset/i,
  /socket hang up/i,
  /network.*error/i,
  // FIX v9 : pattern explicite pour le message de timeout corrigé
  /ollama timeout/i,
  /whisper timeout/i,
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

// ── Per-Modality Circuit Breaker ───────────────────────────────────────────────
//
// FIX v9 : classe dédiée pour chaque modalité afin d'isoler les états.
//
// AVANT (v7/v8) : un seul état partagé dans IntentExtractorService.
//   → 3 timeouts moondream → circuit ouvert → audio et texte bloqués.
//
// APRÈS (v9) : CircuitBreakerPerModality instanciée 3 fois (text/audio/image).
//   → Chaque modalité a son propre compteur d'échecs et son propre état.
//   → Les timeouts moondream n'affectent que le circuit 'image'.

type CircuitState = 'closed' | 'open' | 'half-open';

class CircuitBreakerPerModality {
  private state:         CircuitState = 'closed';
  private failures       = 0;
  private lastFailureAt  = 0;

  constructor(
    private readonly modality:  string,
    private readonly threshold: number,
    private readonly resetMs:   number,
    private readonly logger:    Logger,
  ) {}

  /**
   * Vérifie si le circuit autorise la requête.
   * Lève AiProviderException (503) si OPEN.
   * Permet le passage d'une requête test si HALF-OPEN.
   */
  assertClosed(): void {
    if (this.state === 'closed') return;

    if (this.state === 'open') {
      const elapsed = Date.now() - this.lastFailureAt;
      if (elapsed >= this.resetMs) {
        this.state = 'half-open';
        this.logger.log(
          `AI circuit [${this.modality}] → HALF-OPEN after ${(elapsed / 1000).toFixed(0)}s`,
        );
        return; // Laisser passer cette requête test
      }

      const remaining = Math.ceil((this.resetMs - elapsed) / 1000);
      this.logger.warn(
        `AI circuit [${this.modality}] OPEN — fast-fail. Recovery in ~${remaining}s`,
      );
      throw new AiProviderException(
        `AI ${this.modality} service temporarily unavailable. Please try again in ${remaining} seconds.`,
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
    // half-open : laisser passer
  }

  onSuccess(): void {
    if (this.state !== 'closed') {
      this.logger.log(
        `AI circuit [${this.modality}] → CLOSED (recovered after ${this.failures} failure(s))`,
      );
    }
    this.failures = 0;
    this.state    = 'closed';
  }

  onFailure(): void {
    this.failures++;
    this.lastFailureAt = Date.now();

    if (this.failures >= this.threshold) {
      if (this.state !== 'open') {
        this.logger.warn(
          `AI circuit [${this.modality}] → OPEN after ${this.failures} consecutive failures. ` +
          `Fast-failing for ${this.resetMs / 1000}s.`,
        );
      }
      this.state = 'open';
    }
  }

  getStatus() {
    return {
      modality:      this.modality,
      state:         this.state,
      failures:      this.failures,
      lastFailureAt: this.lastFailureAt,
      recoversAt:    this.state === 'open'
        ? this.lastFailureAt + this.resetMs
        : null,
    };
  }
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

Requête: "j'ai une fuite d'eau sous l'évier"
{"profession":"plumber","is_urgent":false,"problem_description":"water leak under sink","max_radius_km":null,"confidence":0.97}

Requête: "prise électrique qui fait des étincelles"
{"profession":"electrician","is_urgent":true,"problem_description":"electrical outlet sparking","max_radius_km":null,"confidence":0.95}

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

  // FIX v9 — THREE independent circuit breakers (one per modality).
  //
  // Previously: a single shared circuit breaker caused image timeouts
  // (moondream on 8 GB CPU) to block audio and text requests as well.
  //
  // Now: each modality fails independently and recovers independently.
  private readonly circuitText:  CircuitBreakerPerModality;
  private readonly circuitAudio: CircuitBreakerPerModality;
  private readonly circuitImage: CircuitBreakerPerModality;

  private static readonly CIRCUIT_THRESHOLD = 3;
  private static readonly CIRCUIT_RESET_MS  = 30_000;

  constructor(
    @Inject(AI_PROVIDER_TOKEN)
    private readonly ai: IAiProvider,
    @Optional() @Inject('REDIS_CLIENT')
    private readonly redis?: Redis,
  ) {
    this.circuitText  = new CircuitBreakerPerModality('text',  IntentExtractorService.CIRCUIT_THRESHOLD, IntentExtractorService.CIRCUIT_RESET_MS, this.logger);
    this.circuitAudio = new CircuitBreakerPerModality('audio', IntentExtractorService.CIRCUIT_THRESHOLD, IntentExtractorService.CIRCUIT_RESET_MS, this.logger);
    this.circuitImage = new CircuitBreakerPerModality('image', IntentExtractorService.CIRCUIT_THRESHOLD, IntentExtractorService.CIRCUIT_RESET_MS, this.logger);
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  async extractFromText(text: string, uid?: string): Promise<SearchIntent> {
    const trimmed = text.trim().slice(0, 2000);
    if (!trimmed) return { ...FALLBACK };

    if (uid) await this.checkRateLimit(uid);

    // FIX v9 : circuit dédié au texte uniquement
    this.circuitText.assertClosed();

    const cacheKey = this.hashKey(trimmed.toLowerCase());
    const cached   = this.cache.get(cacheKey);
    if (cached) {
      this.logger.debug('Cache hit');
      return cached;
    }

    try {
      const raw    = await this.ai.generateText(trimmed, SYSTEM_PROMPT, { temperature: 0.05, maxTokens: 256 });
      const intent = this.parse(raw);
      this.circuitText.onSuccess();
      this.setCache(cacheKey, intent);
      return intent;
    } catch (err) {
      return this.handleAiError(err, 'text', this.circuitText);
    }
  }

  async extractFromAudio(buffer: Buffer, mime: string, uid?: string): Promise<SearchIntent> {
    // FIX v9 : circuit dédié à l'audio — isolé des échecs image
    this.circuitAudio.assertClosed();

    let transcription: AudioResult;

    try {
      transcription = await this.ai.processAudio(buffer, mime);
      this.circuitAudio.onSuccess();
    } catch (err) {
      return this.handleAiError(err, 'audio', this.circuitAudio);
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

    // FIX v9 : circuit dédié à l'image — les timeouts moondream
    // n'affectent plus le texte ni l'audio
    this.circuitImage.assertClosed();

    try {
      const raw = await this.ai.analyzeImage(
        imageBase64,
        `Identifie le problème domestique visible dans cette image, puis extrait l'intention.\n${SYSTEM_PROMPT}`,
        { temperature: 0.05, maxTokens: 256 },
      );
      this.circuitImage.onSuccess();
      return this.parse(raw);
    } catch (err) {
      return this.handleAiError(err, 'image', this.circuitImage);
    }
  }

  /**
   * État de tous les circuit breakers (pour health check).
   */
  getAllCircuitStatuses() {
    return {
      text:  this.circuitText.getStatus(),
      audio: this.circuitAudio.getStatus(),
      image: this.circuitImage.getStatus(),
    };
  }

  // ── Error handler centralisé ────────────────────────────────────────────────

  private handleAiError(
    err:     unknown,
    context: string,
    circuit: CircuitBreakerPerModality,
  ): never | SearchIntent {
    circuit.onFailure();

    if (isQuotaError(err)) {
      this.logger.warn(`AI quota/rate-limit [${context}]: ${(err as Error).message}`);
      throw new AiRateLimitException();
    }

    if (isOverloadError(err)) {
      this.logger.warn(`AI overloaded/unavailable [${context}]: ${(err as Error).message}`);
      throw new AiProviderException(
        `AI ${context} model temporarily unavailable. Please try again later.`,
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    // Erreur non-classifiée — log complet, retour FALLBACK sans crash.
    this.logger.error(
      `[${context}] Unclassified AI error: ${(err as Error).message}`,
      (err as Error).stack,
    );
    return { ...FALLBACK };
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  private parse(raw: string): SearchIntent {
    const s       = raw.replace(/```json|```/g, '').trim();
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
