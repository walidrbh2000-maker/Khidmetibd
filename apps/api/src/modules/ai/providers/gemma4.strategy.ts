// apps/api/src/modules/ai/providers/gemma4.strategy.ts
//
// ══════════════════════════════════════════════════════════════════════════════
// MIGRATION v14.2 — Correctifs audio Gemma4 natif sur CPU 8 GB RAM
//
// CHANGEMENTS v14.2 vs v14.1 :
//
// 1. VALIDATION TAILLE AUDIO (nouveau)
//    Limite stricte : 5 MB (~30s WAV 16kHz mono)
//    Raison : llama.cpp refuse silencieusement les audio > 30s.
//    Un fichier de 60s ne produit pas d'erreur mais tronque le résultat.
//    Le circuit breaker s'ouvre alors pour rien.
//    → Rejet explicite côté NestJS avant l'envoi à Gemma4.
//
// 2. FORMAT AUDIO NORMALISÉ AVANT ENVOI (nouveau)
//    Certains clients envoient "audio/wav" avec des headers non-standard.
//    On force systématiquement le format "wav" dans l'API call (sauf m4a/mp3).
//    Raison : llama.cpp mtmd utilise le champ "format" pour choisir le décodeur.
//    Un format inconnu → erreur 400 silencieuse "failed to decode image bytes".
//
// 3. TIMEOUT AUDIO AUGMENTÉ (env GEMMA4_TIMEOUT_MS)
//    .env : 30000 → 90000 ms
//    Le strategy lit GEMMA4_TIMEOUT_MS depuis l'env — aucun changement de code.
//    Mais le fallback interne dans processAudio passe de 45s à 90s.
//
// INCHANGÉ vs v14.0 :
//   - Pipeline single-step (audio → JSON intent direct via Gemma4 natif)
//   - Format API OpenAI-compatible : { type: "input_audio", input_audio: {...} }
//   - AUDIO_INTENT_SYSTEM_PROMPT (vocabulaire Darija algérienne)
//   - cleanResponse(), detectImageMime(), normalizeMime(), mimeToExt()
//
// BASE TECHNIQUE :
//   PR ggml-org/llama.cpp#21421 — "mtmd: add Gemma 4 audio conformer encoder support"
//   Statut : MERGÉ dans master (avril 2026)
//   mmproj BF16 requis (recommandé par PR#21421) — f32/f16 fonctionnent mais
//   qualité audio réduite pour l'encodeur conformer USM-style.
//
// FORMAT AUDIO RECOMMANDÉ :
//   WAV 16kHz mono, max 30 secondes (~5 MB)
//   Format envoyé à llama.cpp : { type: "input_audio", input_audio: { data: "base64", format: "wav" } }
// ══════════════════════════════════════════════════════════════════════════════

import { Injectable, Logger } from '@nestjs/common';
import type { IAiProvider, AudioResult } from '../interfaces/ai-provider.interface';

// ── Types internes ────────────────────────────────────────────────────────────

type MessageRole = 'system' | 'user' | 'assistant';

interface TextPart {
  type: 'text';
  text: string;
}

interface ImagePart {
  type: 'image_url';
  image_url: { url: string };
}

interface AudioPart {
  type: 'input_audio';
  input_audio: { data: string; format: string };
}

type ContentPart = TextPart | ImagePart | AudioPart;

interface ChatMessage {
  role:    MessageRole;
  content: string | ContentPart[];
}

interface LlamaCppResponse {
  choices: Array<{
    message: { content: string | null };
  }>;
}

interface LlamaCppErrorBody {
  error?: string | { message?: string };
}

// ── Constantes audio ──────────────────────────────────────────────────────────

// Limite Gemma4 : 30 secondes audio maximum
// WAV 16kHz mono 16-bit = 32 000 bytes/s → 30s = ~960 000 bytes ≈ 1 MB
// WAV 16kHz mono 32-bit = 64 000 bytes/s → 30s = ~1 920 000 bytes ≈ 2 MB
// Marge de sécurité à 5 MB (couvre WAV 44kHz stéréo ~28s)
const MAX_AUDIO_BYTES = 5 * 1024 * 1024; // 5 MB

// Timeout audio par défaut si GEMMA4_TIMEOUT_MS n'est pas défini
// L'audio mel spectrogram sur CPU prend 20-60s selon la longueur
const AUDIO_TIMEOUT_FALLBACK_MS = 90_000;

// ── System prompt audio ───────────────────────────────────────────────────────
//
// Identique au SYSTEM_PROMPT de intent-extractor.service.ts
// Copie intentionnelle pour éviter la dépendance circulaire provider ↔ service.
// Si le prompt évolue dans intent-extractor, répercuter ici.

const AUDIO_INTENT_SYSTEM_PROMPT = `\
Tu es l'extracteur d'intention de Khidmeti — application algérienne de services à domicile.
Tu analyses des messages vocaux en DARIJA ALGÉRIENNE, Français, Arabe standard, ou tout mélange.

⚠️  RÈGLE ABSOLUE : Réponds UNIQUEMENT avec le JSON brut ci-dessous.
     Aucun markdown, aucune transcription, aucune explication, aucun texte avant/après.

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

# Message vocal Darija (plomberie)
{"profession":"plumber","is_urgent":false,"problem_description":"water leaking from ceiling","max_radius_km":null,"confidence":0.95}

# Message vocal urgent (électricité totale)
{"profession":"electrician","is_urgent":true,"problem_description":"total power outage in house, immediate need","max_radius_km":null,"confidence":0.98}

# Message vocal mix Darija + Français
{"profession":"ac_repair","is_urgent":false,"problem_description":"air conditioner not cooling, hot weather","max_radius_km":null,"confidence":0.96}

# Message vocal ambigu → faible confiance
{"profession":null,"is_urgent":false,"problem_description":"unspecified problem at home","max_radius_km":null,"confidence":0.1}
`;

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Supprime les balises de "thinking" que Gemma4 peut émettre malgré
 * enable_thinking:false (cas rares ou ancienne version de llama.cpp).
 * Nettoie également les backticks markdown résiduels.
 */
function cleanResponse(raw: string): string {
  return raw
    .replace(/<\|think\|>[\s\S]*?<\|\/think\|>/gi, '')
    .replace(/<think>[\s\S]*?<\/think>/gi, '')
    .replace(/```(?:json)?\s*/g, '')
    .replace(/```/g, '')
    .trim();
}

// ─────────────────────────────────────────────────────────────────────────────

@Injectable()
export class Gemma4Strategy implements IAiProvider {
  private readonly logger = new Logger(Gemma4Strategy.name);

  private readonly gemma4Url:     string;
  private readonly gemma4Timeout: number;

  constructor() {
    this.gemma4Url     = process.env['GEMMA4_BASE_URL']    ?? 'http://ai-gemma4:8011';
    this.gemma4Timeout = parseInt(process.env['GEMMA4_TIMEOUT_MS'] ?? String(AUDIO_TIMEOUT_FALLBACK_MS), 10);

    this.logger.log(
      `✅ Gemma4Strategy v14.2 — single-model multimodal (texte + image + audio natif)\n` +
      `   └─ endpoint  : ${this.gemma4Url}\n` +
      `   └─ timeout   : ${this.gemma4Timeout}ms\n` +
      `   └─ audio max : ${MAX_AUDIO_BYTES / 1024 / 1024} MB (~30s WAV 16kHz)\n` +
      `   ℹ️  Audio natif via llama.cpp PR#21421 — mmproj BF16 requis`,
    );
  }

  // ── IAiProvider : generateText ─────────────────────────────────────────────

  async generateText(
    prompt:       string,
    systemPrompt: string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    return this.chat(
      [
        { role: 'system', content: systemPrompt },
        { role: 'user',   content: prompt },
      ],
      { temperature: opts.temperature ?? 0.05, maxTokens: opts.maxTokens ?? 512 },
    );
  }

  // ── IAiProvider : analyzeImage ─────────────────────────────────────────────

  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const mime    = this.detectImageMime(Buffer.from(imageBase64, 'base64'));
    const dataUrl = `data:${mime};base64,${imageBase64}`;

    return this.chat(
      [
        { role: 'system', content: prompt },
        {
          role:    'user',
          content: [
            { type: 'image_url', image_url: { url: dataUrl } },
            {
              type: 'text',
              text: 'Analyse cette image et extrait l\'intention de service à domicile au format JSON exact demandé.',
            },
          ],
        },
      ],
      { temperature: opts.temperature ?? 0.05, maxTokens: opts.maxTokens ?? 512 },
    );
  }

  // ── IAiProvider : processAudio ─────────────────────────────────────────────
  //
  // v14.1 — Correctifs audio natif Gemma4 sur CPU 8 GB RAM
  //
  // VALIDATION (nouveau v14.1) :
  //   1. Taille : rejet si > MAX_AUDIO_BYTES (5 MB ≈ 30s WAV 16kHz)
  //      Raison : llama.cpp tronque silencieusement l'audio > 30s
  //      → le circuit breaker s'ouvre pour un timeout évitable.
  //
  // FORMAT AUDIO (normalisé v14.1) :
  //   On force "wav" comme format par défaut pour les MIME non reconnus.
  //   llama.cpp mtmd utilise ce champ pour sélectionner le décodeur audio.
  //   Un format inconnu → "failed to decode image bytes" (erreur 400).
  //
  // PIPELINE (inchangé vs v14.0) :
  //   Audio → Gemma4 (audio natif PR#21421) → JSON intent direct
  //   Format API : { type: "input_audio", input_audio: { data: "base64", format: "wav" } }

  async processAudio(
    buffer: Buffer,
    mime:   string,
    _opts:  { temperature?: number; maxTokens?: number } = {},
  ): Promise<AudioResult> {
    // ── Validation taille (v14.1) ────────────────────────────────────────────
    if (buffer.length > MAX_AUDIO_BYTES) {
      throw new Error(
        `Audio trop long : ${(buffer.length / 1024 / 1024).toFixed(1)} MB ` +
        `(max ${MAX_AUDIO_BYTES / 1024 / 1024} MB ≈ 30s WAV 16kHz mono). ` +
        `Raccourcissez l'enregistrement ou réduisez la qualité (16kHz mono recommandé).`,
      );
    }

    const normalizedMime = this.normalizeMime(mime);
    const ext            = this.mimeToExt(normalizedMime);
    const audioBase64    = buffer.toString('base64');

    this.logger.debug(
      `Audio natif Gemma4 v14.1 — ` +
      `format=${ext} taille=${(buffer.length / 1024).toFixed(0)} KB ` +
      `mime_original=${mime} mime_normalisé=${normalizedMime}`,
    );

    // ── Envoi à Gemma4 (format API mtmd OpenAI-compatible) ───────────────────
    //
    // Google recommande de placer l'audio AVANT le texte dans le contenu user.
    // Le system prompt contient : schéma JSON + professions + vocabulaire Darija.
    const raw = await this.chat(
      [
        {
          role:    'system',
          content: AUDIO_INTENT_SYSTEM_PROMPT,
        },
        {
          role: 'user',
          content: [
            {
              type: 'input_audio',
              input_audio: { data: audioBase64, format: ext },
            },
            {
              type: 'text',
              text:
                'Écoute ce message vocal en Darija algérienne (ou Français/Arabe/mix) ' +
                'et extrait l\'intention de service à domicile au format JSON exact demandé.',
            },
          ],
        },
      ],
      {
        temperature: _opts.temperature ?? 0.05,
        maxTokens:   _opts.maxTokens   ?? 512,
      },
    );

    // language 'auto' : Gemma4 comprend le mix nativement (140+ langues)
    return { text: raw, language: 'auto' };
  }

  // ── Privé : chat générique ────────────────────────────────────────────────
  //
  // Point d'entrée unique vers ai-gemma4:8011 pour texte, images ET audio.
  //
  // PARAMÈTRES GEMMA4 (Google recommandations) :
  //   temp=1.0, top_p=0.95, top_k=64 en général
  //   temp=0.05 overridé ici pour JSON structuré (pas de créativité)
  //
  // ENABLE_THINKING: false
  //   Désactive le Chain-of-Thought <|think|> pour un JSON direct.
  //   cleanResponse() filtre les tags résiduels si le serveur ne supporte pas.

  private async chat(
    messages: ChatMessage[],
    opts: { temperature?: number; maxTokens?: number },
  ): Promise<string> {
    const ctrl  = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.gemma4Timeout);

    try {
      const res = await fetch(`${this.gemma4Url}/v1/chat/completions`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        signal:  ctrl.signal,
        body: JSON.stringify({
          model:      'gemma4',
          messages,
          stream:     false,
          temperature: opts.temperature ?? 0.05,
          max_tokens:  opts.maxTokens   ?? 512,
          top_p:       0.95,
          top_k:       64,
          chat_template_kwargs: { enable_thinking: false },
        }),
      }).catch((e: unknown) => {
        if ((e as Error).name === 'AbortError') throw e;
        throw new Error(
          `Gemma4 fetch failed [${this.gemma4Url}]: ${(e as Error).message}`,
        );
      });

      if (!res.ok) {
        const rawBody = await res.text().catch(() => res.statusText);
        let errMsg = rawBody;
        try {
          const parsed = JSON.parse(rawBody) as LlamaCppErrorBody;
          if (parsed.error) {
            errMsg = typeof parsed.error === 'string'
              ? parsed.error
              : (parsed.error.message ?? rawBody);
          }
        } catch { /* raw body non-JSON */ }

        if (res.status === 404) {
          throw new Error(
            `Gemma4 modèle introuvable sur ${this.gemma4Url}. ` +
            `Lancez : make download-gemma4`,
          );
        }

        // Erreur 400/422 audio : format non supporté ou mmproj absent/incorrect
        if (res.status === 400 || res.status === 422) {
          throw new Error(
            `Gemma4 audio non supporté (${res.status}): ${errMsg}. ` +
            `Vérifiez : (1) llama.cpp image récente avec PR#21421, ` +
            `(2) mmproj BF16 présent dans docker/models/gemma4/, ` +
            `(3) format audio WAV 16kHz mono < 30s.`,
          );
        }

        throw new Error(`Gemma4 ${res.status} [${this.gemma4Url}]: ${errMsg}`);
      }

      const data    = await res.json() as LlamaCppResponse;
      const content = data.choices?.[0]?.message?.content;

      if (!content || typeof content !== 'string') {
        throw new Error(
          `Gemma4 a retourné un contenu vide [${this.gemma4Url}] — modèle chargé ?`,
        );
      }

      return cleanResponse(content);

    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        throw new Error(
          `Gemma4 timeout (${this.gemma4Timeout}ms) [${this.gemma4Url}]. ` +
          `Audio : vérifiez que le fichier fait <30s et que GEMMA4_TIMEOUT_MS=90000 dans .env.`,
        );
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /**
   * Détecte le MIME type d'une image par magic bytes.
   * Plus fiable que le Content-Type HTTP (souvent absent ou incorrect).
   */
  private detectImageMime(buf: Buffer): string {
    if (buf.length < 12) return 'image/jpeg';
    if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff)
      return 'image/jpeg';
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47)
      return 'image/png';
    if (
      buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
      buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50
    ) return 'image/webp';
    if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46)
      return 'image/gif';
    return 'image/jpeg';
  }

  /**
   * Normalise les MIME types audio vers des formes canoniques.
   * Cas fréquents : Android envoie audio/x-wav, iOS envoie audio/x-m4a.
   * application/octet-stream → on suppose WAV (format le plus courant en dev).
   */
  private normalizeMime(mime: string): string {
    if (!mime || mime === 'application/octet-stream') return 'audio/wav';
    const map: Record<string, string> = {
      // WAV — toutes les variantes
      'audio/x-wav':       'audio/wav',
      'audio/wave':        'audio/wav',
      'audio/vnd.wave':    'audio/wav',
      // M4A / MP4 — iOS envoie audio/x-m4a, Android envoie audio/m4a ou audio/mp4
      // BUG v14.1 : 'audio/m4a' manquait → tombait dans le fallback 'audio/wav'
      //             → llama.cpp recevait des données m4a avec format='wav' → erreur decode
      'audio/m4a':         'audio/mp4',
      'audio/x-m4a':       'audio/mp4',
      'audio/x-mp4':       'audio/mp4',
      // MP3
      'audio/mpeg':        'audio/mp3',
      'audio/x-mpeg':      'audio/mp3',
      'audio/mpeg3':       'audio/mp3',
      'audio/x-mpeg3':     'audio/mp3',
      // OGG
      'audio/ogg':         'audio/ogg',
      'audio/x-ogg':       'audio/ogg',
      'audio/vorbis':      'audio/ogg',
    };
    return map[mime] ?? mime;
  }

  /**
   * Convertit un MIME type audio en extension de fichier pour l'API llama.cpp.
   * llama.cpp mtmd utilise l'extension pour sélectionner le décodeur audio.
   * Défaut "wav" si inconnu — le plus compatible avec libsndfile.
   */
  private mimeToExt(mime: string): string {
    const map: Record<string, string> = {
      'audio/wav':  'wav',
      'audio/mp3':  'mp3',
      'audio/mp4':  'm4a',
      'audio/ogg':  'ogg',
      'audio/flac': 'flac',
      'audio/webm': 'webm',
      'audio/aac':  'aac',
    };
    return map[mime] ?? 'wav';
  }
}
