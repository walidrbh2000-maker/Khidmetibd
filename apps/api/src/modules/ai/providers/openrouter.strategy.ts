// apps/api/src/modules/ai/providers/openrouter.strategy.ts
//
// ARCHITECTURE — Double backend stratégique
// ─────────────────────────────────────────────────────────────────────────────
// ┌──────────────┬───────────────────────────────────────┬─────────┐
// │ Méthode      │ Backend                               │ Coût    │
// ├──────────────┼───────────────────────────────────────┼─────────┤
// │ generateText │ OpenRouter → google/gemma-4-31b-it:free│ GRATUIT │
// │ analyzeImage │ OpenRouter → google/gemma-4-31b-it:free│ GRATUIT │
// │ processAudio │ Google AI Studio → GEMINI_AUDIO_MODEL │ payant  │
// └──────────────┴───────────────────────────────────────┴─────────┘
//
// POURQUOI CETTE SÉPARATION ?
//   • Gemma 4 31B est disponible GRATUITEMENT sur OpenRouter (quota généreux).
//   • L'API Files de Google AI Studio est UNIQUE à Google — aucun équivalent
//     sur OpenRouter pour la transcription audio multilingue (Darija, Arabe...).
//   • Cette stratégie réduit les coûts API à ~0 pour 95% des appels.
//
// CONFIGURATION .env requise :
//   AI_PROVIDER=openrouter
//   OPENROUTER_API_KEY=sk-or-v1-...
//   GEMINI_API_KEY=AIza...            (requis uniquement pour l'audio)
//   GEMINI_AUDIO_MODEL=gemini-2.5-flash-lite

import { Injectable, Logger } from '@nestjs/common';
import { GoogleGenAI } from '@google/genai';
import type { Content, Part } from '@google/genai';
import type { IAiProvider, AudioResult } from '../interfaces/ai-provider.interface';

// ── Types OpenRouter (API compatible OpenAI) ──────────────────────────────────

interface OpenRouterTextPart {
  type: 'text';
  text: string;
}

interface OpenRouterImagePart {
  type:      'image_url';
  image_url: { url: string; detail?: 'low' | 'high' | 'auto' };
}

type OpenRouterContentPart = OpenRouterTextPart | OpenRouterImagePart;

interface OpenRouterMessage {
  role:    'system' | 'user' | 'assistant';
  content: string | OpenRouterContentPart[];
}

interface OpenRouterResponse {
  choices: Array<{
    message:       { content: string | null };
    finish_reason: string;
  }>;
  usage?: {
    prompt_tokens:     number;
    completion_tokens: number;
    total_tokens:      number;
  };
  error?: { message: string; code?: string };
}

// ── MIME audio supportés par Gemini Files API ────────────────────────────────

const AUDIO_MIME_SUPPORTED = new Set([
  'audio/wav', 'audio/mp3', 'audio/aiff', 'audio/aac',
  'audio/ogg', 'audio/flac', 'audio/webm', 'audio/mp4',
]);

// ── Détection de transcriptions parasites (audio silencieux) ────────────────

const TIMESTAMP_ONLY_RE = /^(?:\d{1,2}:\d{2}\s*)+$/;

function isGarbageTranscript(text: string): boolean {
  const t = text.trim();
  if (t.length < 3)              return true;
  if (TIMESTAMP_ONLY_RE.test(t)) return true;
  if (/^[\d\s:.,\-]+$/.test(t)) return true;
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────

@Injectable()
export class OpenRouterStrategy implements IAiProvider {
  private readonly logger = new Logger(OpenRouterStrategy.name);

  // ── OpenRouter ────────────────────────────────────────────────────────────
  private readonly openRouterApiKey:  string;
  private readonly openRouterModel:   string;
  private readonly timeoutMs:         number;
  private static readonly BASE_URL  = 'https://openrouter.ai/api/v1/chat/completions';

  // ── Google AI Studio (audio uniquement) ──────────────────────────────────
  private readonly ai:          GoogleGenAI;
  private readonly AUDIO_MODEL: string;

  constructor() {
    // ── Validation OpenRouter ───────────────────────────────────────────────
    const openRouterKey = process.env['OPENROUTER_API_KEY'];
    if (!openRouterKey) {
      throw new Error('OPENROUTER_API_KEY is missing. Get your free key at https://openrouter.ai/keys');
    }
    this.openRouterApiKey = openRouterKey;
    this.openRouterModel  = process.env['OPENROUTER_MODEL'] ?? 'google/gemma-4-31b-it:free';
    this.timeoutMs        = parseInt(process.env['OPENROUTER_TIMEOUT_MS'] ?? '35000', 10);

    // ── Validation Google AI Studio (audio) ────────────────────────────────
    const geminiKey = process.env['GEMINI_API_KEY'];
    if (!geminiKey) {
      throw new Error(
        'GEMINI_API_KEY is missing. It is required for audio transcription ' +
        '(Google AI Studio Files API). Get yours at https://aistudio.google.com/apikey',
      );
    }
    this.AUDIO_MODEL = process.env['GEMINI_AUDIO_MODEL'] ?? 'gemini-2.0-flash';
    this.ai          = new GoogleGenAI({ apiKey: geminiKey });

    this.logger.log(
      `✅ OpenRouterStrategy ready\n` +
      `   ├─ text / image : ${this.openRouterModel} via OpenRouter (GRATUIT)\n` +
      `   └─ audio        : ${this.AUDIO_MODEL} via Google AI Studio`,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // generateText — OpenRouter (GRATUIT)
  // ═══════════════════════════════════════════════════════════════════════════

  async generateText(
    prompt:       string,
    systemPrompt: string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const messages: OpenRouterMessage[] = [
      { role: 'system', content: systemPrompt },
      { role: 'user',   content: prompt       },
    ];
    return this.callOpenRouter(messages, opts);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // analyzeImage — OpenRouter vision (GRATUIT)
  //
  // Gemma 4 31B est multimodal nativement.
  // OpenRouter expose la vision via le format standard OpenAI :
  //   content: [{ type: 'image_url', image_url: { url: 'data:image/jpeg;base64,...' } }]
  // ═══════════════════════════════════════════════════════════════════════════

  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const buffer   = Buffer.from(imageBase64, 'base64');
    const mimeType = this.detectImageMime(buffer);

    const messages: OpenRouterMessage[] = [{
      role:    'user',
      content: [
        {
          type:      'image_url',
          image_url: {
            url:    `data:${mimeType};base64,${imageBase64}`,
            detail: 'high',
          },
        },
        { type: 'text', text: prompt },
      ],
    }];

    return this.callOpenRouter(messages, opts);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // processAudio — Google AI Studio Files API (PAYANT mais requis)
  //
  // OpenRouter/Gemma 4 ne supporte pas encore l'audio natif.
  // Google AI Studio offre la Files API avec support Darija / Arabe / Français
  // via son modèle flash-lite à coût très faible.
  //
  // Implémentation identique à GeminiStrategy.processAudio() — source of truth.
  // ═══════════════════════════════════════════════════════════════════════════

  async processAudio(
    audioBuffer: Buffer,
    mime:        string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<AudioResult> {
    const mimeType = this.detectAudioMime(audioBuffer)
                  ?? this.normalizeMimeForAudio(mime);

    if (!AUDIO_MIME_SUPPORTED.has(mimeType)) {
      this.logger.warn(`Audio MIME "${mimeType}" may not be officially supported — proceeding anyway`);
    }

    const uploadedFile = await this.uploadToFilesApi(audioBuffer, mimeType, 'audio');

    try {
      const contents: Content[] = [{
        role:  'user',
        parts: [
          {
            fileData: {
              fileUri:  uploadedFile.uri,
              mimeType: uploadedFile.mimeType,
            },
          } as Part,
          {
            text: [
              'Transcris cet audio en texte exact.',
              'Réponds UNIQUEMENT en JSON brut, sans markdown, sans explication:',
              '{"text":"<transcription verbatim>","language":"<code ISO 639-1>"}',
            ].join('\n'),
          },
        ],
      }];

      const response = await this.ai.models.generateContent({
        model:    this.AUDIO_MODEL,
        contents,
        config: {
          temperature:     0.0,
          maxOutputTokens: opts.maxTokens ?? 800,
        },
      });

      const result = this.parseAudioJson(response.text ?? '');

      // Guard : transcription parasite sur audio silencieux
      if (isGarbageTranscript(result.text)) {
        this.logger.debug(
          `Audio transcript is garbage (likely silent audio): ` +
          `"${result.text.trim().slice(0, 60)}" — returning empty text`,
        );
        return { text: '', language: result.language };
      }

      return result;
    } finally {
      this.deleteFileQuietly(uploadedFile.name);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Privé — Appel HTTP OpenRouter
  // ═══════════════════════════════════════════════════════════════════════════

  private async callOpenRouter(
    messages: OpenRouterMessage[],
    opts:     { temperature?: number; maxTokens?: number },
  ): Promise<string> {
    const controller = new AbortController();
    const timer      = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const res = await fetch(OpenRouterStrategy.BASE_URL, {
        method:  'POST',
        signal:  controller.signal,
        headers: {
          'Content-Type':  'application/json',
          'Authorization': `Bearer ${this.openRouterApiKey}`,
          // Requis par OpenRouter pour les analytics de routing (optionnel mais recommandé)
          'HTTP-Referer':  process.env['APP_URL'] ?? 'https://khidmeti.com',
          'X-Title':       'Khidmeti',
        },
        body: JSON.stringify({
          model:        this.openRouterModel,
          messages,
          temperature:  opts.temperature ?? 0.05,
          max_tokens:   opts.maxTokens   ?? 600,
          // Désactiver le mode "thinking" pour la génération JSON structurée
          // (plus rapide + déterministe pour l'extraction d'intent)
          transforms: [],
        }),
      });

      if (!res.ok) {
        const errText = await res.text().catch(() => res.statusText);

        // Détecter les erreurs de quota OpenRouter (429)
        if (res.status === 429) {
          throw new Error(`OpenRouter rate limit (429): ${errText}`);
        }

        // Modèle temporairement indisponible (503)
        if (res.status === 503 || res.status === 502) {
          throw new Error(`OpenRouter model unavailable (${res.status}): ${errText}`);
        }

        throw new Error(`OpenRouter HTTP ${res.status}: ${errText}`);
      }

      const data = await res.json() as OpenRouterResponse;

      // Vérifier si OpenRouter a retourné une erreur JSON
      if (data.error) {
        throw new Error(`OpenRouter API error: ${data.error.message} (code: ${data.error.code ?? 'unknown'})`);
      }

      const content = data.choices?.[0]?.message?.content ?? '';

      if (data.usage) {
        this.logger.debug(
          `OpenRouter tokens — prompt: ${data.usage.prompt_tokens} | ` +
          `completion: ${data.usage.completion_tokens} | ` +
          `total: ${data.usage.total_tokens}`,
        );
      }

      return content;
    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        throw new Error(`OpenRouter timeout after ${this.timeoutMs}ms — consider increasing OPENROUTER_TIMEOUT_MS`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Privé — Google AI Studio Files API helpers (audio seulement)
  // ═══════════════════════════════════════════════════════════════════════════

  private async uploadToFilesApi(
    buffer:      Buffer,
    mimeType:    string,
    displayName: string,
  ): Promise<{ uri: string; mimeType: string; name: string }> {
    const blob       = new Blob([new Uint8Array(buffer)], { type: mimeType });
    const uniqueName = `${displayName}_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

    const uploaded = await this.ai.files.upload({
      file:   blob,
      config: { mimeType, displayName: uniqueName },
    });

    if (!uploaded.uri || !uploaded.mimeType) {
      throw new Error('Files API upload failed — missing uri or mimeType in response');
    }

    return {
      uri:      uploaded.uri,
      mimeType: uploaded.mimeType,
      name:     uploaded.name ?? '',
    };
  }

  private deleteFileQuietly(name: string | undefined): void {
    if (!name) return;
    this.ai.files.delete({ name }).catch((err: unknown) => {
      this.logger.debug(
        `Files API cleanup skipped for "${name}": ${(err as Error).message}`,
      );
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Privé — Détection MIME par magic bytes
  // ═══════════════════════════════════════════════════════════════════════════

  private detectImageMime(buffer: Buffer): string {
    if (buffer.length < 4) return 'image/jpeg';

    // JPEG : FF D8 FF
    if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) {
      return 'image/jpeg';
    }
    // PNG : 89 50 4E 47
    if (buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4e && buffer[3] === 0x47) {
      return 'image/png';
    }
    // GIF : 47 49 46
    if (buffer[0] === 0x47 && buffer[1] === 0x49 && buffer[2] === 0x46) {
      return 'image/gif';
    }
    // WebP : RIFF....WEBP
    if (
      buffer.length >= 12 &&
      buffer[0]  === 0x52 && buffer[1]  === 0x49 && buffer[2]  === 0x46 && buffer[3]  === 0x46 &&
      buffer[8]  === 0x57 && buffer[9]  === 0x45 && buffer[10] === 0x42 && buffer[11] === 0x50
    ) {
      return 'image/webp';
    }

    this.logger.warn('Could not detect image MIME from magic bytes — defaulting to image/jpeg');
    return 'image/jpeg';
  }

  private detectAudioMime(buffer: Buffer): string | null {
    if (buffer.length < 12) return null;

    // WAV : RIFF....WAVE
    if (
      buffer[0] === 0x52 && buffer[1] === 0x49 && buffer[2] === 0x46 && buffer[3] === 0x46 &&
      buffer[8] === 0x57 && buffer[9] === 0x41 && buffer[10] === 0x56 && buffer[11] === 0x45
    ) return 'audio/wav';

    // FLAC : fLaC
    if (buffer[0] === 0x66 && buffer[1] === 0x4c && buffer[2] === 0x61 && buffer[3] === 0x43) return 'audio/flac';

    // OGG : OggS
    if (buffer[0] === 0x4f && buffer[1] === 0x67 && buffer[2] === 0x67 && buffer[3] === 0x53) return 'audio/ogg';

    // MP3 : ID3 header
    if (buffer[0] === 0x49 && buffer[1] === 0x44 && buffer[2] === 0x33) return 'audio/mp3';

    // MP3 : sync bits
    if (buffer[0] === 0xff && (buffer[1] & 0xe0) === 0xe0) return 'audio/mp3';

    // WebM : EBML
    if (buffer[0] === 0x1a && buffer[1] === 0x45 && buffer[2] === 0xdf && buffer[3] === 0xa3) return 'audio/webm';

    // MP4 / M4A : ftyp box
    if (buffer.length >= 8 && buffer[4] === 0x66 && buffer[5] === 0x74 && buffer[6] === 0x79 && buffer[7] === 0x70) {
      return 'audio/mp4';
    }

    // AAC : ADTS sync
    if (buffer[0] === 0xff && (buffer[1] & 0xf0) === 0xf0) return 'audio/aac';

    return null;
  }

  private normalizeMimeForAudio(mime: string): string {
    if (!mime || mime === 'application/octet-stream') {
      this.logger.warn('Audio MIME unspecified or octet-stream — defaulting to audio/mp4 (M4A)');
      return 'audio/mp4';
    }
    const aliases: Record<string, string> = {
      'audio/x-wav':  'audio/wav',
      'audio/x-m4a':  'audio/mp4',
      'audio/mpeg':   'audio/mp3',
      'audio/x-mpeg': 'audio/mp3',
    };
    return aliases[mime] ?? mime;
  }

  private parseAudioJson(raw: string): AudioResult {
    const clean = raw
      .replace(/```json|```/g, '')
      .replace(/<\|channel>thought[\s\S]*?<channel\|>/g, '')
      .trim();

    const i = clean.indexOf('{');
    const j = clean.lastIndexOf('}');
    if (i !== -1 && j !== -1) {
      try {
        return JSON.parse(clean.slice(i, j + 1)) as AudioResult;
      } catch { /* fall through */ }
    }
    return { text: clean || '', language: 'auto' };
  }
}
