// ══════════════════════════════════════════════════════════════════════════════
// GeminiStrategy — Google AI API backend
//
// ARCHITECTURE — WHY TWO MODELS:
//   gemma-4-31b-it : Text ✅  |  Image ✅  |  Audio ✗ (not supported via API)
//   gemini-2.0-flash: Text ✅  |  Image ✅  |  Audio ✅
//
//   Audio pipeline (2 steps):
//     1. Upload audio buffer → Google Files API
//     2. Transcribe with GEMINI_AUDIO_MODEL (default: gemini-2.0-flash)
//     3. extractFromText() takes over → gemma-4-31b-it extracts intent from text
//
//   Image pipeline:
//     1. Detect true MIME type from magic bytes (Flutter sends application/octet-stream)
//     2. Upload via Files API → URI-based reference avoids base64 size limits
//     3. gemma-4-31b-it analyses image via fileData Part
//
// All three input modalities share the same GEMINI_API_KEY — no extra credentials.
// ══════════════════════════════════════════════════════════════════════════════

import { Injectable, Logger } from '@nestjs/common';
import { GoogleGenAI } from '@google/genai';
import type { Content, Part, GenerateContentConfig } from '@google/genai';
import type { IAiProvider, AudioResult } from '../interfaces/ai-provider.interface';

// ── MIME type tables ───────────────────────────────────────────────────────────

/** Supported image MIME types for gemma-4-31b-it via Gemini API */
const IMAGE_MIME_SUPPORTED = new Set(['image/jpeg', 'image/png', 'image/gif', 'image/webp']);

/**
 * Supported audio MIME types for gemini-2.0-flash via Gemini API.
 * Ref: https://ai.google.dev/gemini-api/docs/audio
 */
const AUDIO_MIME_SUPPORTED = new Set([
  'audio/wav', 'audio/mp3', 'audio/aiff', 'audio/aac',
  'audio/ogg', 'audio/flac', 'audio/webm', 'audio/mp4',
]);

@Injectable()
export class GeminiStrategy implements IAiProvider {
  private readonly logger = new Logger(GeminiStrategy.name);
  private readonly ai: GoogleGenAI;

  /** Model for text + image intent extraction */
  private readonly MODEL: string;

  /**
   * Dedicated model for audio transcription only.
   * gemma-4-31b-it does NOT support audio input via the Gemini API —
   * audio modality is only available on E2B / E4B edge variants.
   * gemini-2.0-flash supports audio natively and shares the same API key.
   */
  private readonly AUDIO_MODEL: string;

  constructor() {
    const apiKey = process.env['GEMINI_API_KEY'];
    if (!apiKey) throw new Error('GEMINI_API_KEY is missing');

    this.MODEL       = process.env['GEMMA4_MODEL']        ?? 'gemma-4-31b-it';
    this.AUDIO_MODEL = process.env['GEMINI_AUDIO_MODEL']  ?? 'gemini-2.0-flash';
    this.ai          = new GoogleGenAI({ apiKey });

    this.logger.log(
      `✅ GeminiStrategy ready — intent: ${this.MODEL} | audio-transcription: ${this.AUDIO_MODEL}`,
    );
  }

  // ── IAiProvider implementation ─────────────────────────────────────────────

  /**
   * Generate text from a prompt (text-only, uses gemma-4-31b-it).
   */
  async generateText(
    prompt:       string,
    systemPrompt: string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const config: GenerateContentConfig = {
      systemInstruction: systemPrompt,
      temperature:       opts.temperature ?? 0.05,
      maxOutputTokens:   opts.maxTokens   ?? 600,
    };

    const response = await this.ai.models.generateContent({
      model:    this.MODEL,
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      config,
    });

    return response.text ?? '';
  }

  /**
   * Analyze an image and return text (uses gemma-4-31b-it via Files API).
   *
   * WHY Files API instead of inline base64?
   *   - Flutter commonly sends images with MIME type "application/octet-stream".
   *   - The Files API lets us declare the correct MIME type on upload,
   *     decoupling it from what Flutter reports in the multipart header.
   *   - Avoids base64 overhead for images > ~4 MB.
   */
  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const buffer   = Buffer.from(imageBase64, 'base64');
    const mimeType = this.detectImageMime(buffer);

    // Upload to Files API with the correct MIME type
    const uploadedFile = await this.uploadToFilesApi(buffer, mimeType, 'image');

    try {
      const contents: Content[] = [{
        role:  'user',
        parts: [
          // fileData avoids re-sending bytes and uses the hosted URI
          { fileData: { fileUri: uploadedFile.uri, mimeType: uploadedFile.mimeType } } as Part,
          { text: prompt },
        ],
      }];

      const response = await this.ai.models.generateContent({
        model:    this.MODEL,
        contents,
        config: {
          temperature:     opts.temperature ?? 0.05,
          maxOutputTokens: opts.maxTokens   ?? 600,
        },
      });

      return response.text ?? '';
    } finally {
      // Best-effort cleanup — file expires automatically after 48h anyway
      this.deleteFileQuietly(uploadedFile.name);
    }
  }

  /**
   * Transcribe audio and return { text, language } (uses gemini-2.0-flash).
   *
   * WHY a different model for audio?
   *   gemma-4-31b-it does NOT support audio input via the Google AI API.
   *   Audio modality is only available natively on the E2B / E4B edge variants.
   *   Using gemini-2.0-flash (same API key, no extra cost tier) for transcription
   *   then handing the resulting text back to gemma-4-31b-it for intent extraction
   *   is the correct architectural split.
   *
   * WHY Files API?
   *   Inline base64 audio triggers "Unsupported MIME type: application/octet-stream"
   *   when Flutter sends the raw bytes without a proper Content-Type header.
   *   The Files API upload lets us declare the true MIME type independently.
   */
  async processAudio(
    audioBuffer: Buffer,
    mime:        string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<AudioResult> {
    // Resolve the true MIME type — Flutter and React Native often report
    // "application/octet-stream" for recorded audio files.
    const mimeType = this.detectAudioMime(audioBuffer)
                  ?? this.normalizeMimeForAudio(mime);

    if (!AUDIO_MIME_SUPPORTED.has(mimeType)) {
      this.logger.warn(`Audio MIME "${mimeType}" may not be supported — proceeding anyway`);
    }

    // Step 1 — upload audio to Files API (returns a hosted URI)
    const uploadedFile = await this.uploadToFilesApi(audioBuffer, mimeType, 'audio');

    try {
      // Step 2 — transcribe using gemini-2.0-flash (supports audio natively)
      const contents: Content[] = [{
        role:  'user',
        parts: [
          { fileData: { fileUri: uploadedFile.uri, mimeType: uploadedFile.mimeType } } as Part,
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
          temperature:     0.0,   // deterministic for transcription
          maxOutputTokens: opts.maxTokens ?? 800,
        },
      });

      return this.parseAudioJson(response.text ?? '');
    } finally {
      this.deleteFileQuietly(uploadedFile.name);
    }
  }

  // ── Files API helpers ──────────────────────────────────────────────────────

  /**
   * Upload a buffer to the Gemini Files API and return the file metadata.
   *
   * WHY `new Uint8Array(buffer)` instead of passing `buffer` directly?
   *
   * Node.js allocates `Buffer` instances from a shared memory pool backed by a
   * `SharedArrayBuffer`. The `Blob` constructor (Web API, available in Node ≥ 18)
   * only accepts `ArrayBuffer` — passing a `SharedArrayBuffer`-backed view causes:
   *
   *   TypeError: Type 'SharedArrayBuffer' is not assignable to type 'ArrayBuffer'
   *
   * `new Uint8Array(buffer)` performs a copy into a fresh, owned `ArrayBuffer`,
   * breaking the shared-pool reference and satisfying the `Blob` contract.
   * The copy is O(n) but unavoidable given the Web API constraint.
   */
  private async uploadToFilesApi(
    buffer:      Buffer,
    mimeType:    string,
    displayName: string,
  ): Promise<{ uri: string; mimeType: string; name: string }> {
    // Detach from Node's shared Buffer pool → guaranteed plain ArrayBuffer for Blob
    const blob       = new Blob([new Uint8Array(buffer)], { type: mimeType });
    const uniqueName = `${displayName}_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

    const uploaded = await this.ai.files.upload({
      file:   blob,
      config: { mimeType, displayName: uniqueName },
    });

    if (!uploaded.uri || !uploaded.mimeType) {
      throw new Error(`Files API upload failed — missing uri or mimeType in response`);
    }

    return {
      uri:      uploaded.uri,
      mimeType: uploaded.mimeType,
      name:     uploaded.name ?? '',
    };
  }

  /** Delete a Files API file silently (non-fatal) */
  private deleteFileQuietly(name: string | undefined): void {
    if (!name) return;
    this.ai.files.delete({ name }).catch((err: unknown) => {
      this.logger.debug(`Files API cleanup skipped for "${name}": ${(err as Error).message}`);
    });
  }

  // ── Magic-byte MIME detection ──────────────────────────────────────────────

  /**
   * Detect image MIME type from magic bytes.
   * Flutter's MultipartFile.fromBytes() often sets mimeType to null or
   * "application/octet-stream" — magic bytes are the only reliable source.
   */
  private detectImageMime(buffer: Buffer): string {
    if (buffer.length < 4) return 'image/jpeg';

    // JPEG: FF D8 FF
    if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return 'image/jpeg';

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (
      buffer[0] === 0x89 && buffer[1] === 0x50 &&
      buffer[2] === 0x4e && buffer[3] === 0x47
    ) return 'image/png';

    // GIF: 47 49 46
    if (buffer[0] === 0x47 && buffer[1] === 0x49 && buffer[2] === 0x46) return 'image/gif';

    // WebP: RIFF....WEBP
    if (
      buffer.length >= 12 &&
      buffer[0] === 0x52 && buffer[1] === 0x49 && buffer[2] === 0x46 && buffer[3] === 0x46 &&
      buffer[8] === 0x57 && buffer[9] === 0x45 && buffer[10] === 0x42 && buffer[11] === 0x50
    ) return 'image/webp';

    // Default fallback — gemma-4 handles JPEG most reliably
    this.logger.warn('Could not detect image MIME from magic bytes — defaulting to image/jpeg');
    return 'image/jpeg';
  }

  /**
   * Detect audio MIME type from magic bytes.
   * Returns null if format is unrecognised (caller falls back to normaliseAudioMime).
   */
  private detectAudioMime(buffer: Buffer): string | null {
    if (buffer.length < 12) return null;

    // WAV: RIFF....WAVE
    if (
      buffer[0] === 0x52 && buffer[1] === 0x49 && buffer[2] === 0x46 && buffer[3] === 0x46 &&
      buffer[8] === 0x57 && buffer[9] === 0x41 && buffer[10] === 0x56 && buffer[11] === 0x45
    ) return 'audio/wav';

    // FLAC: fLaC
    if (
      buffer[0] === 0x66 && buffer[1] === 0x4c &&
      buffer[2] === 0x61 && buffer[3] === 0x43
    ) return 'audio/flac';

    // OGG: OggS
    if (
      buffer[0] === 0x4f && buffer[1] === 0x67 &&
      buffer[2] === 0x67 && buffer[3] === 0x53
    ) return 'audio/ogg';

    // MP3: ID3 tag
    if (buffer[0] === 0x49 && buffer[1] === 0x44 && buffer[2] === 0x33) return 'audio/mp3';

    // MP3: sync word (FF Ex or FF Fx)
    if (buffer[0] === 0xff && (buffer[1] & 0xe0) === 0xe0) return 'audio/mp3';

    // WebM / Matroska: 1A 45 DF A3
    if (
      buffer[0] === 0x1a && buffer[1] === 0x45 &&
      buffer[2] === 0xdf && buffer[3] === 0xa3
    ) return 'audio/webm';

    // MP4 / M4A: ftyp box at offset 4
    if (
      buffer.length >= 8 &&
      buffer[4] === 0x66 && buffer[5] === 0x74 &&
      buffer[6] === 0x79 && buffer[7] === 0x70
    ) return 'audio/mp4';

    // AAC ADTS: FF F0 or FF F1 ...
    if (buffer[0] === 0xff && (buffer[1] & 0xf0) === 0xf0) return 'audio/aac';

    return null;
  }

  /**
   * Sanitise a reported MIME type for audio — replaces the generic
   * "application/octet-stream" (Flutter default) with "audio/mp4" which
   * is accepted by the Files API and covers M4A / AAC recordings from iOS/Android.
   */
  private normalizeMimeForAudio(mime: string): string {
    if (!mime || mime === 'application/octet-stream') {
      this.logger.warn('Audio MIME unspecified or octet-stream — defaulting to audio/mp4 (M4A)');
      return 'audio/mp4';
    }
    // Normalise common aliases
    const aliases: Record<string, string> = {
      'audio/x-wav':  'audio/wav',
      'audio/x-m4a':  'audio/mp4',
      'audio/mpeg':   'audio/mp3',
      'audio/x-mpeg': 'audio/mp3',
    };
    return aliases[mime] ?? mime;
  }

  // ── JSON parsers ───────────────────────────────────────────────────────────

  private parseAudioJson(raw: string): AudioResult {
    const clean = raw
      .replace(/```json|```/g, '')
      .replace(/<\|channel>thought[\s\S]*?<channel\|>/g, '') // strip Gemma thinking tags
      .trim();

    const i = clean.indexOf('{');
    const j = clean.lastIndexOf('}');
    if (i !== -1 && j !== -1) {
      try {
        return JSON.parse(clean.slice(i, j + 1)) as AudioResult;
      } catch { /* fall through */ }
    }
    // Non-JSON response — treat the entire text as a transcription
    return { text: clean || '', language: 'auto' };
  }
}
