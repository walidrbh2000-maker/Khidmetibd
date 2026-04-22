// apps/api/src/modules/ai/services/intent-extractor.service.ts
//
// v14 — Audio natif Gemma4 : pipeline single-step (audio → JSON intent direct)
//
// ══════════════════════════════════════════════════════════════════════════════
// CHANGEMENTS v14 vs v13 :
//
// 1. AUDIO PIPELINE SIMPLIFIÉ
//    v13 : processAudio(Whisper STT) → texte → generateText(Gemma4) → JSON
//    v14 : processAudio(Gemma4 natif) → JSON intent direct (une seule inférence)
//    → Le JSON revient directement de Gemma4 via processAudio()
//    → extractFromAudio() appelle parseIntent() directement, plus extractFromText()
//
// 2. CIRCUIT BREAKER AUDIO CONSERVÉ
//    Même si audio et texte partagent désormais le même container ai-gemma4,
//    le circuit audio reste isolé. Raison : les timeouts audio (traitement mel
//    spectrogram) sont structurellement différents des timeouts texte.
//    Un fichier audio lourd (30s) ne doit pas ouvrir le circuit texte.
//
// 3. COMMENTAIRE MISE À JOUR
//    "Whisper STT" → "Gemma4 audio natif"
//    Le SYSTEM_PROMPT rest inchangé (qualité Darija algérienne conservée).
// ══════════════════════════════════════════════════════════════════════════════

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
  /audio non support/i,  // v14 : format audio non supporté par llama.cpp
];

function isQuotaError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return QUOTA_PATTERNS.some((p) => p.test(msg));
}

function isOverloadError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return !isQuotaError(err) && OVERLOAD_PATTERNS.some((p) => p.test(msg));
}

// ── Détection transcriptions parasites ────────────────────────────────────────
//
// v14 : utilisé pour détecter les réponses Gemma4 audio vides ou parasites
// (audio silencieux, trop court, bruit pur)

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
//
// v14 : 2 circuits indépendants (inchangé vs v13)
//   circuitGemma4 : texte + images (même endpoint ai-gemma4:8011)
//   circuitAudio  : audio Gemma4 natif (même endpoint, circuit isolé)
//
// Isolation nécessaire même si même endpoint :
//   Audio = traitement mel spectrogram sur CPU = latence structurellement plus haute
//   Timeout audio ne doit pas déclencher le circuit texte/image
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
// SYSTEM PROMPT — Darija Algérienne v14
//
// Identique à v13. Aucune modification nécessaire :
//   - Le prompt reste le même pour texte et image
//   - Pour audio, Gemma4Strategy utilise AUDIO_INTENT_SYSTEM_PROMPT (copie)
//   - Si ce prompt évolue, répercuter dans gemma4.strategy.ts
// ══════════════════════════════════════════════════════════════════════════════

const SYSTEM_PROMPT = `\
Tu es l'extracteur d'intention de Khidmeti — application algérienne de services à domicile.
Tu analyses des demandes en DARIJA ALGÉRIENNE, Français, Arabe standard, ou tout mélange.

⚠️  RÈGLE ABSOLUE : Réponds UNIQUEMENT avec le JSON brut ci-dessous.
     Aucun markdown, aucune explication, aucune réflexion, aucun texte avant/après.

═══ SCHÉMA JSON EXACT ═══════════════════════════════════════════════════════
{"profession":<string|null>,"is_urgent":<bool>,"problem_description":<string>,"max_radius_km":<number|null>,"confidence":<number>}

═══ PROFESSIONS VALIDES (mot exact uniquement) ═══════════════════════════════
plumber | electrician | cleaner | painter | carpenter | gardener
ac_repair | appliance_repair | mason | mechanic | mover

═══ RÈGLES MÉTIER ═══════════════════════════════════════════════════════════
is_urgent = true SEULEMENT si :
  • Fuite d'eau active qui inonde (ماء يطيح بزاف / inondation)
  • Coupure électrique totale de la maison (ضو قاطع كامل / coupure totale)
  • Fuite de gaz / odeur de gaz (ريحة قاز / fuite gaz)
  • Serrure cassée la nuit / porte bloquée avec personnes à l'intérieur
  → NE PAS mettre urgent pour : clim qui chauffe, frigo qui refroidit moins, peinture à refaire

problem_description : anglais, factuel, max 120 chars
max_radius_km : si la personne mentionne une distance ou un quartier spécifique, null sinon
confidence : 0.0 à 1.0 — mettre 0.0 si profession introuvable, pas null

═══ DARIJA ALGÉRIENNE → PROFESSION ═════════════════════════════════════════
  سباك / بلومبيي / نمير / حنفية / طاسة / يطيح ماء / تسرب / مسدود → plumber
  كهربجي / ضو قاطع / فيوز / بريزة / كابل محروق / الكهربا → electrician
  صبّاغ / دهّان / صبغة / طلاء / الجدار ويبان → painter
  نجار / باب خايس / قفل / خشب → carpenter
  كليمو / كليماتيزور / تكييف / ما يبردش / ما يسخنش → ac_repair
  فريدجيدير / ماشينة غسيل / ليف / ميكرو / طابشة / ما تخدمش → appliance_repair
  بنّاء / جدار / بلاط / خلوط / متشقق / فيسور → mason
  فراشة / مسسة / نظافة / تنظيف الدار → cleaner
  حديقة / عشب / نقلم / سقي / شجرة → gardener
  ميكانيسيان / سيارة / تبان / كرودان → mechanic
  نقل عفش / شلالة / ننقلو / دار جديدة → mover

═══ EXEMPLES FEW-SHOT ══════════════════════════════════════════════════════

# Darija algérienne pure (plomberie)
Requête: "عندي ماء ساقط من السقف ديال الدار"
{"profession":"plumber","is_urgent":false,"problem_description":"water leaking from ceiling","max_radius_km":null,"confidence":0.95}

# Darija urgente (électricité totale)
Requête: "الضوء طاح في الدار كاملة وخاصني حل درووك"
{"profession":"electrician","is_urgent":true,"problem_description":"total power outage in house, immediate need","max_radius_km":null,"confidence":0.98}

# Mix Darija + Français (très courant en Algérie)
Requête: "الكليمو تاعي ما يبردش et il fait trop chaud maintenant"
{"profession":"ac_repair","is_urgent":false,"problem_description":"air conditioner not cooling, hot weather","max_radius_km":null,"confidence":0.96}

# Darija (plomberie - évier)
Requête: "الطاسة تاع الكوزينة مسدودة وما تفرّغش"
{"profession":"plumber","is_urgent":false,"problem_description":"kitchen sink drain completely blocked","max_radius_km":null,"confidence":0.94}

# Français algérien (électricité)
Requête: "j'ai une prise électrique qui fait des étincelles dans le salon"
{"profession":"electrician","is_urgent":true,"problem_description":"sparking electrical outlet in living room","max_radius_km":null,"confidence":0.97}

# Darija (électroménager - frigo)
Requête: "الفريدجيدير تاعي ما يبردش، كل ما نحطو فيه يخسر"
{"profession":"appliance_repair","is_urgent":false,"problem_description":"refrigerator not cooling, food spoiling","max_radius_km":null,"confidence":0.95}

# Darija (menuiserie - porte)
Requête: "الباب تاع الغرفة خايس وما يقفلش، خاصني نجار"
{"profession":"carpenter","is_urgent":false,"problem_description":"bedroom door broken, does not close properly","max_radius_km":null,"confidence":0.97}

# Arabe standard (maçonnerie)
Requête: "يوجد تشقق في الجدار الخارجي للمنزل ويتسع يوماً بعد يوم"
{"profession":"mason","is_urgent":false,"problem_description":"widening crack in exterior wall","max_radius_km":null,"confidence":0.93}

# Darija (peinture)
Requête: "الصبغة تاع الدار طاحت وخاصني نصبغ قبل العيد"
{"profession":"painter","is_urgent":false,"problem_description":"house paint peeling, needs repainting before Eid","max_radius_km":null,"confidence":0.94}

# Darija (déménagement)
Requête: "خاصني ننقل العفش من حي بن عمر لدار جديدة نهاية الشهر"
{"profession":"mover","is_urgent":false,"problem_description":"furniture relocation to new apartment end of month","max_radius_km":null,"confidence":0.92}

# Mix Français + Arabe (ménage)
Requête: "j'ai besoin d'une femme de ménage pour nettoyer mon appartement كل أسبوع"
{"profession":"cleaner","is_urgent":false,"problem_description":"weekly apartment cleaning service needed","max_radius_km":null,"confidence":0.95}

# Darija (jardinage)
Requête: "الحديقة تاعنا عندها عشب كثير ومحتاجة تقليم الشجر"
{"profession":"gardener","is_urgent":false,"problem_description":"garden overgrown, trees need trimming","max_radius_km":null,"confidence":0.93}

# Darija (lave-linge urgence inondation)
Requête: "الماشينة تاع الغسيل خلّات الماء يطيح وغرقت الأرضية"
{"profession":"appliance_repair","is_urgent":true,"problem_description":"washing machine flooding the floor","max_radius_km":null,"confidence":0.96}

# Darija (mécanique voiture)
Requête: "السيارة تاعي ما تحركش والمحرك يدير صوت غريب"
{"profession":"mechanic","is_urgent":false,"problem_description":"car won't start, strange engine noise","max_radius_km":null,"confidence":0.91}

# Requête ambiguë → faible confiance
Requête: "عندي مشكل في الدار"
{"profession":null,"is_urgent":false,"problem_description":"unspecified problem at home","max_radius_km":null,"confidence":0.1}

# Audio imparfait (Darija + bruit de fond) — v14 : Gemma4 gère mieux que Whisper
Requête: "اه خويا عندي... الحنفية تاع... هه... السقف يدرب"
{"profession":"plumber","is_urgent":false,"problem_description":"tap or ceiling water issue (noisy audio)","max_radius_km":null,"confidence":0.7}
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

  // ── Circuit breakers (v14 : 2 circuits, isolés par modalité) ──────────────
  //
  // circuitGemma4 : texte + images (même endpoint ai-gemma4:8011)
  // circuitAudio  : audio Gemma4 natif (même endpoint, circuit séparé)
  //                 → isolation latence audio (mel spectrogram CPU) vs texte
  //
  // Threshold = 3 échecs → OPEN pendant 30s
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
      const raw    = await this.ai.generateText(trimmed, SYSTEM_PROMPT, { temperature: 0.05, maxTokens: 512 });
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
   *
   * v14 — Pipeline single-step via Gemma4 audio natif (llama.cpp PR#21421) :
   *   Audio → Gemma4 → JSON intent (une seule inférence, zéro Whisper)
   *
   * v13 (supprimé) :
   *   Audio → Whisper STT → texte → Gemma4 intent (deux inférences + service externe)
   *
   * Formats recommandés : WAV 16kHz mono
   * Formats acceptés    : WAV, MP3, M4A, OGG, FLAC, WebM
   * Limite Gemma4       : 30 secondes maximum
   */
  async extractFromAudio(buffer: Buffer, mime: string, uid?: string): Promise<SearchIntent> {
    this.circuitAudio.assertClosed();

    let audioResult: AudioResult;
    try {
      // v14 : processAudio → Gemma4 audio natif → JSON intent directement
      // Le system prompt AUDIO_INTENT_SYSTEM_PROMPT est embarqué dans Gemma4Strategy
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

    // v14 : Gemma4 retourne le JSON intent directement depuis l'audio
    // parseIntent() extrait et valide le JSON de la réponse Gemma4
    const intent = this.parseIntent(text);

    this.logger.debug(
      `Audio intent — profession=${intent.profession ?? 'null'} ` +
      `urgent=${intent.is_urgent} confidence=${intent.confidence}`,
    );

    return intent;
  }

  /**
   * Extraction depuis une image.
   * Pipeline v14 (inchangé vs v13) : Gemma4 single-step (image + texte → JSON)
   */
  async extractFromImage(imageBase64: string, uid?: string): Promise<SearchIntent> {
    if (uid) await this.checkRateLimit(uid);

    this.circuitGemma4.assertClosed();

    try {
      const raw = await this.ai.analyzeImage(
        imageBase64,
        SYSTEM_PROMPT,
        { temperature: 0.05, maxTokens: 512 },
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
