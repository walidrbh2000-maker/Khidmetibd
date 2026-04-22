// apps/api/src/modules/ai/providers/gemma4.strategy.ts
//
// ══════════════════════════════════════════════════════════════════════════════
// MIGRATION v14 — Gemma4 E2B : modèle unique texte + image + AUDIO natif
//
// AVANT (v13) :
//   - ai-gemma4:8011 (llama.cpp) → texte + images
//   - ai-audio:8000  (Whisper)   → audio STT → texte → Gemma4
//   → 2 services IA, 2 circuits, pipeline deux-étapes pour audio
//
// APRÈS (v14) :
//   - ai-gemma4:8011 (llama.cpp) → texte + images + AUDIO natif
//   → 1 seul service IA, inférence unique audio → JSON intent
//
// BASE TECHNIQUE :
//   PR ggml-org/llama.cpp#21421 — "mtmd: add Gemma 4 audio conformer encoder support"
//   Statut : MERGÉ dans master (avril 2026), testé CPU + Vulkan sur E2B et E4B
//   Ref issue : ggml-org/llama.cpp#21325
//   Précision : BF16 mmproj recommandé — f32 mmproj (déjà téléchargé) = encore meilleur
//
// FORMAT AUDIO API (OpenAI-compatible, llama.cpp/mtmd) :
//   { type: "input_audio", input_audio: { data: "<base64>", format: "wav" } }
//   Recommandation : audio WAV 16kHz mono pour meilleure précision
//   Limite Gemma4   : 30 secondes maximum
//
// AVANTAGES vs Whisper :
//   ✅ ~2 GB RAM économisés (Whisper retiré)
//   ✅ 1 seul container IA (au lieu de 2)
//   ✅ Audio → JSON intent en une seule inférence (plus de pipeline deux-étapes)
//   ✅ Darija algérienne mieux comprise (Gemma4 = 140+ langues, mixte Darija/FR natif)
//   ✅ Pas de téléchargement Whisper au premier lancement
//   ✅ Scalabilité E4B GPU : même code, performances x5-10
//
// NOTE FORMAT AUDIO :
//   WAV  : supporté nativement par llama.cpp/libsndfile ✅
//   M4A  : si refusé, convertir en WAV côté client (recommandé)
//   MP3  : même recommandation
//   Pour conversion automatique côté serveur : ajouter ffmpeg-static (v15)
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

// ── System prompt audio ───────────────────────────────────────────────────────
//
// Identique au SYSTEM_PROMPT de intent-extractor.service.ts
// Séparé ici pour éviter la dépendance circulaire entre le provider et le service.
// Si le prompt évolue dans intent-extractor, mettre à jour ici aussi.
//
// Ce prompt est utilisé en mode audio natif (single-step audio → JSON intent).
// L'audio et le texte sont traités en une seule inférence par Gemma4.

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
 * enable_thinking:false (cas rares ou version llama.cpp ancienne).
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
    this.gemma4Timeout = parseInt(process.env['GEMMA4_TIMEOUT_MS'] ?? '45000', 10);

    this.logger.log(
      `✅ Gemma4Strategy v14 — single-model multimodal (texte + image + audio)\n` +
      `   └─ endpoint : ${this.gemma4Url}  (timeout=${this.gemma4Timeout}ms)\n` +
      `   ℹ️  Audio natif via llama.cpp PR#21421 — mmproj f32 inclut l'encodeur audio`,
    );
  }

  // ── IAiProvider : generateText ─────────────────────────────────────────────
  //
  // Extraction d'intention depuis un texte (Darija / Français / Arabe / mix).

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
  //
  // Single-step avec Gemma4 natif — image + texte dans une seule inférence.

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
  // v14 — Audio natif Gemma4 via llama.cpp (PR#21421 mergé)
  //
  // PIPELINE v14 (single-step) :
  //   Audio → Gemma4 (audio + system prompt) → JSON intent
  //   SUPPRIMÉ : Whisper STT → texte → Gemma4 (pipeline deux-étapes v13)
  //
  // FORMAT API llama.cpp/mtmd (OpenAI-compatible) :
  //   { type: "input_audio", input_audio: { data: "base64...", format: "wav" } }
  //
  // TIMEOUT AUDIO : 45s (plus long que texte — décodage mel spectrogram sur CPU)
  // FORMATS RECOMMANDÉS : WAV 16kHz mono (qualité optimale pour conformer encoder)
  // LIMITE GEMMA4 : 30 secondes d'audio maximum
  //
  // COMPATIBILITÉ INTERFACE :
  //   Retourne AudioResult { text: jsonString, language: 'auto' }
  //   Le jsonString est le JSON intent (parsé par IntentExtractorService)

  async processAudio(
    buffer: Buffer,
    mime:   string,
    _opts:  { temperature?: number; maxTokens?: number } = {},
  ): Promise<AudioResult> {
    const normalizedMime = this.normalizeMime(mime);
    const ext            = this.mimeToExt(normalizedMime);
    const audioBase64    = buffer.toString('base64');

    this.logger.debug(
      `Audio natif Gemma4 — format=${ext} taille=${(buffer.length / 1024).toFixed(0)}KB`,
    );

    // Gemma4 : recommandation Google — placer audio AVANT le texte dans le prompt
    // Le système prompt contient le schéma JSON + vocabulaire Darija algérienne
    const raw = await this.chat(
      [
        {
          role: 'system',
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

    // raw = réponse JSON de Gemma4 (le JSON intent)
    // language 'auto' : Gemma4 comprend le mix nativement, pas besoin de détecter
    return { text: raw, language: 'auto' };
  }

  // ── Privé : chat générique ────────────────────────────────────────────────
  //
  // Unique méthode HTTP vers ai-gemma4:8011 (texte, images ET audio).
  //
  // GEMMA4 PARAMS RECOMMANDÉS (Google) :
  //   temp=1.0, top_p=0.95, top_k=64 — mais on override temp=0.05 pour JSON structuré
  //
  // ENABLE_THINKING : false → supprime le CoT <|think|> pour un JSON direct
  //   Si le serveur llama.cpp ne supporte pas l'option, cleanResponse() filtre les tags.

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
        throw new Error(`Gemma4 fetch failed [${this.gemma4Url}]: ${(e as Error).message}`);
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
        } catch { /* raw body pas du JSON */ }

        if (res.status === 404) {
          throw new Error(
            `Gemma4 modèle introuvable sur ${this.gemma4Url}. Lancez: make download-gemma4`,
          );
        }

        // Audio spécifique : si 400/422 → format audio probablement non supporté
        if (res.status === 400 || res.status === 422) {
          throw new Error(
            `Gemma4 audio non supporté (${res.status}): ${errMsg}. ` +
            `Assurez-vous que llama.cpp >= b4900 et que le mmproj f32 est chargé. ` +
            `Format WAV 16kHz recommandé.`,
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
          `Audio : vérifiez que le fichier fait <30s et que le mmproj f32 est présent.`,
        );
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  private detectImageMime(buf: Buffer): string {
    if (buf.length < 12) return 'image/jpeg';
    if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
    if (
      buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
      buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50
    ) return 'image/webp';
    if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46) return 'image/gif';
    return 'image/jpeg';
  }

  private normalizeMime(mime: string): string {
    const map: Record<string, string> = {
      'audio/x-wav':  'audio/wav',
      'audio/x-m4a':  'audio/mp4',
      'audio/mpeg':   'audio/mp3',
      'audio/x-mpeg': 'audio/mp3',
    };
    if (!mime || mime === 'application/octet-stream') return 'audio/wav';
    return map[mime] ?? mime;
  }

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
