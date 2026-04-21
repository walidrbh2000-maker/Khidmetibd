// apps/api/src/modules/ai/services/intent-extractor.service.ts
//
// FIX v7 — Circuit Breaker + Fix OVERLOAD_PATTERNS + Meilleur surfacing d'erreurs
//
// ═══════════════════════════════════════════════════════════════════════════════
// PROBLÈMES RÉSOLUS
// ═══════════════════════════════════════════════════════════════════════════════
//
// PROBLÈME 1 — Silent FALLBACK (le plus critique)
//
//   AVANT : Quand Ollama runner crashait (OOM), l'erreur
//     "llama runner process has terminated: %!w(<nil>)"
//   ne matchait AUCUN OVERLOAD_PATTERN → tombait dans le catch générique
//   → return { ...FALLBACK } silencieux → HTTP 200 avec confidence=0
//   → Flutter pensait que la requête avait réussi (mais sans résultat utile)
//   → l'utilisateur voyait un résultat vide sans message d'erreur
//
//   APRÈS : Nouveaux patterns OVERLOAD détectent "runner process has terminated",
//   "fetch failed", "ECONNREFUSED" etc. → lèvent AiProviderException (HTTP 503)
//   → Flutter reçoit un 503 clair et peut proposer "Réessayer"
//
// PROBLÈME 2 — Cascade de timeouts (16x timeout × 120s = 32 minutes de blocage)
//
//   AVANT : Si Ollama était en train de crasher et redémarrer, chaque appel
//   attendait 120 secondes avant de timeout. Plusieurs utilisateurs simultanés
//   pouvaient bloquer toutes les workers NestJS.
//
//   APRÈS : Circuit Breaker — après 3 échecs consécutifs, le circuit s'ouvre
//   et les requêtes suivantes échouent IMMÉDIATEMENT (< 1ms) avec 503 pendant
//   30 secondes, puis le circuit se remet en half-open pour tester une requête.
//
// PROBLÈME 3 — "fetch failed" quand Whisper redémarre après exit 137
//
//   AVANT : Même problème — tombait dans catch générique → FALLBACK silencieux
//   APRÈS : "fetch failed" dans OVERLOAD_PATTERNS → 503 propre
//
// ═══════════════════════════════════════════════════════════════════════════════
// CIRCUIT BREAKER — Comportement
// ═══════════════════════════════════════════════════════════════════════════════
//
//   ┌─────────────────────────────────────────────────────────────────────┐
//   │  CLOSED (normal)   ──3 failures──►  OPEN (fast-fail 30s)           │
//   │      ▲                                      │                       │
//   │      └──── success ◄── HALF-OPEN ◄── 30s elapsed                  │
//   └─────────────────────────────────────────────────────────────────────┘
//
//   CLOSED    : opération normale, chaque requête va jusqu'à Ollama/Whisper
//   OPEN      : fail immédiat avec 503, aucune requête envoyée (protège la RAM)
//   HALF-OPEN : laisse passer UNE requête test — si succès → CLOSED, sinon → OPEN
//
//   Paramètres :
//     CIRCUIT_THRESHOLD = 3 failures consécutives pour ouvrir
//     CIRCUIT_RESET_MS  = 30 secondes en open avant de tenter half-open
//
// ═══════════════════════════════════════════════════════════════════════════════

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
// QUOTA    (HTTP 429) — hard rate-limit, ne pas réessayer immédiatement.
// OVERLOAD (HTTP 503) — transitoire, Ollama/Whisper en cours de redémarrage.
//                       Le circuit breaker protège contre la cascade de timeouts.

const QUOTA_PATTERNS: RegExp[] = [
  /quota/i,
  /resource.?exhausted/i,
  /rate.?limit/i,
  /all ai providers exhausted/i,
  /429/,
];

/**
 * Patterns indiquant une surcharge/indisponibilité transitoire → HTTP 503.
 *
 * FIX v7 — Ajout des patterns manquants qui causaient des FALLBACK silencieux :
 *
 *   "runner process has terminated" — Ollama runner tué par OOM (cgroup Docker).
 *     LocalStrategy.chat() extrait désormais cette string du body JSON Ollama,
 *     permettant à ce pattern de la capturer.
 *
 *   "empty or null content" — Ollama renvoie content=null quand runner instable.
 *     LocalStrategy.chat() lève maintenant cette erreur explicitement.
 *
 *   "fetch failed" / "ECONNREFUSED" / "ECONNRESET" / "socket hang up" —
 *     Erreurs réseau quand Whisper ou Ollama est en cours de redémarrage.
 *     LocalStrategy enveloppe ces erreurs avec un message clair.
 *
 *   "whisper fetch failed" — Ajouté par LocalStrategy.processAudio() FIX v7.
 *     Distingue les pannes Whisper des pannes Ollama dans les logs.
 *
 *   "ollama fetch failed" — Ajouté par LocalStrategy.chat() FIX v7.
 *     Réseau vers Ollama coupé (container redémarrage).
 */
const OVERLOAD_PATTERNS: RegExp[] = [
  /503/,
  /unavailable/i,
  /high demand/i,
  /model.*overload/i,
  /temporarily.*unavailable/i,
  /please try again later/i,
  /requires more system memory/i,      // Ollama OOM — "requires more system memory (X GiB needed)"
  /not enough.*memory/i,               // Formulation générique mémoire insuffisante
  /runner process has terminated/i,    // FIX v7 : Ollama runner tué par OOM cgroup
  /llama runner/i,                     // FIX v7 : Toute erreur "llama runner ..." d'Ollama
  /empty or null content/i,            // FIX v7 : Ollama content=null (runner instable)
  /fetch failed/i,                     // FIX v7 : Erreur réseau générique (fetch API)
  /ollama fetch failed/i,              // FIX v7 : Ollama non-joignable
  /whisper fetch failed/i,             // FIX v7 : Whisper non-joignable (après exit 137)
  /econnrefused/i,                     // FIX v7 : Port refusé (container pas encore démarré)
  /econnreset/i,                       // FIX v7 : Connexion réinitialisée
  /socket hang up/i,                   // FIX v7 : Fermeture prématurée
  /network.*error/i,                   // FIX v7 : Erreur réseau générique
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

// ── Circuit Breaker ────────────────────────────────────────────────────────────
//
// Protège NestJS workers contre la cascade de timeouts lors des crashes Ollama.
//
// POURQUOI c'est critique :
//   - Ollama timeout = 120s
//   - NestJS pool = N workers
//   - Sans circuit breaker : N workers × 120s = minutages bloqués avant récupération
//   - Avec circuit breaker : après 3 échecs → fail immédiat pour 30s → recovery
//
// DESIGN — state machine à 3 états (IEEE 1998 pattern) :
//   closed → (failures >= threshold) → open
//   open   → (elapsed >= reset_ms)   → half-open
//   half-open → success              → closed
//   half-open → failure              → open (reset timer)

type CircuitState = 'closed' | 'open' | 'half-open';

interface CircuitStatus {
  state:              CircuitState;
  failures:           number;
  lastFailureAt:      number;       // epoch ms, 0 = never
  recoversAt:         number | null; // epoch ms, null if closed
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

  // ── Circuit Breaker state ──────────────────────────────────────────────────
  // FIX v7 : Protège contre la cascade de timeouts lors des crashes Ollama/Whisper.
  private circuitState:         CircuitState = 'closed';
  private circuitFailures       = 0;
  private circuitLastFailureAt  = 0;

  private static readonly CIRCUIT_THRESHOLD = 3;       // failures avant ouverture
  private static readonly CIRCUIT_RESET_MS  = 30_000;  // 30s en open avant half-open

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

    // Circuit breaker check — fail fast si Ollama est en cours de recovery
    this.assertCircuitClosed('text');

    const cacheKey = this.hashKey(trimmed.toLowerCase());
    const cached   = this.cache.get(cacheKey);
    if (cached) {
      this.logger.debug('Cache hit');
      return cached;
    }

    try {
      const raw    = await this.ai.generateText(trimmed, SYSTEM_PROMPT, { temperature: 0.05, maxTokens: 256 });
      const intent = this.parse(raw);
      this.onCircuitSuccess();
      this.setCache(cacheKey, intent);
      return intent;
    } catch (err) {
      return this.handleAiError(err, 'extractFromText');
    }
  }

  async extractFromAudio(buffer: Buffer, mime: string, uid?: string): Promise<SearchIntent> {
    // Circuit breaker check (Whisper utilise le même circuit)
    this.assertCircuitClosed('audio');

    let transcription: AudioResult;

    try {
      transcription = await this.ai.processAudio(buffer, mime);
      this.onCircuitSuccess();
    } catch (err) {
      return this.handleAiError(err, 'extractFromAudio');
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

    // Circuit breaker check
    this.assertCircuitClosed('image');

    try {
      const raw = await this.ai.analyzeImage(
        imageBase64,
        `Identifie le problème domestique visible dans cette image, puis extrait l'intention.\n${SYSTEM_PROMPT}`,
        { temperature: 0.05, maxTokens: 256 },
      );
      this.onCircuitSuccess();
      return this.parse(raw);
    } catch (err) {
      return this.handleAiError(err, 'extractFromImage');
    }
  }

  /**
   * Retourne l'état actuel du circuit breaker.
   * Utilisable par un health check endpoint.
   */
  getCircuitStatus(): CircuitStatus {
    const recoversAt =
      this.circuitState === 'open'
        ? this.circuitLastFailureAt + IntentExtractorService.CIRCUIT_RESET_MS
        : null;

    return {
      state:         this.circuitState,
      failures:      this.circuitFailures,
      lastFailureAt: this.circuitLastFailureAt,
      recoversAt,
    };
  }

  // ── Circuit Breaker ─────────────────────────────────────────────────────────

  /**
   * Vérifie si le circuit est ouvert et lève une exception immédiate si c'est le cas.
   * Transition OPEN → HALF-OPEN si le délai de reset est écoulé.
   *
   * @param context Label pour le log (text / audio / image)
   */
  private assertCircuitClosed(context: string): void {
    if (this.circuitState === 'closed') return;

    if (this.circuitState === 'open') {
      const elapsed = Date.now() - this.circuitLastFailureAt;
      if (elapsed >= IntentExtractorService.CIRCUIT_RESET_MS) {
        this.circuitState = 'half-open';
        this.logger.log(
          `AI circuit breaker → HALF-OPEN after ${(elapsed / 1000).toFixed(0)}s — testing recovery`,
        );
        return; // Laisser passer cette requête test
      }

      const remaining = Math.ceil(
        (IntentExtractorService.CIRCUIT_RESET_MS - elapsed) / 1000,
      );
      this.logger.warn(
        `AI circuit breaker OPEN — rejecting [${context}] request. ` +
        `Recovery in ~${remaining}s`,
      );
      throw new AiProviderException(
        `AI service temporarily unavailable. Please try again in ${remaining} seconds.`,
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
    // half-open : laisser passer
  }

  private onCircuitSuccess(): void {
    if (this.circuitState !== 'closed') {
      this.logger.log(
        `AI circuit breaker → CLOSED (recovered after ${this.circuitFailures} failure(s))`,
      );
    }
    this.circuitFailures = 0;
    this.circuitState    = 'closed';
  }

  private onCircuitFailure(): void {
    this.circuitFailures++;
    this.circuitLastFailureAt = Date.now();

    if (this.circuitFailures >= IntentExtractorService.CIRCUIT_THRESHOLD) {
      if (this.circuitState !== 'open') {
        this.logger.warn(
          `AI circuit breaker → OPEN after ${this.circuitFailures} consecutive failures. ` +
          `Fast-failing requests for ${IntentExtractorService.CIRCUIT_RESET_MS / 1000}s.`,
        );
      }
      this.circuitState = 'open';
    }
  }

  // ── Error handler centralisé ────────────────────────────────────────────────
  //
  // Centralise la logique d'erreur qui était dupliquée dans chaque extract*().
  // Retourne toujours : soit lève une exception HTTP, soit retourne FALLBACK.

  private handleAiError(err: unknown, context: string): never | SearchIntent {
    this.onCircuitFailure();

    if (isQuotaError(err)) {
      this.logger.warn(`AI quota/rate-limit [${context}]: ${(err as Error).message}`);
      throw new AiRateLimitException();
    }

    if (isOverloadError(err)) {
      this.logger.warn(`AI service overloaded/unavailable [${context}]: ${(err as Error).message}`);
      throw new AiProviderException(
        'AI model temporarily unavailable. Please try again later.',
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    // Erreur non-classifiée — log complet, retour FALLBACK sans crash.
    // N'inclut PAS les erreurs réseau/OOM (déjà interceptées ci-dessus).
    this.logger.error(
      `[${context}] Unclassified AI error: ${(err as Error).message}`,
      (err as Error).stack,
    );
    return { ...FALLBACK };
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
