// apps/api/src/modules/ai/providers/local.strategy.ts
//
// Backend IA 100% local — aucune dépendance externe.
//
// ┌──────────────┬──────────────────────────────────────┬─────────────────┐
// │ Méthode      │ Service                              │ RAM (8 GB CPU)  │
// ├──────────────┼──────────────────────────────────────┼─────────────────┤
// │ generateText │ Ollama → gemma4:e2b                  │ ~3 GB (chargé)  │
// │ analyzeImage │ Ollama → gemma4:e2b (multimodal)     │ partagé         │
// │ processAudio │ faster-whisper → small int8 CPU      │ ~500 MB fixe    │
// └──────────────┴──────────────────────────────────────┴─────────────────┘
//
// Optimisations 8 GB RAM / CPU :
//   num_ctx = 2048  → contexte minimal suffisant pour l'extraction d'intent
//   think   = false → désactive le mode raisonnement (inutile + consommateur)
//   OLLAMA_KEEP_ALIVE=3m → libère les ~3 GB après 3 min d'inactivité

import { Injectable, Logger } from '@nestjs/common';
import type { IAiProvider, AudioResult } from '../interfaces/ai-provider.interface';

// ── Types internes ────────────────────────────────────────────────────────────

interface OllamaMessage {
  role:    'system' | 'user' | 'assistant';
  content: string | OllamaPart[];
}

interface OllamaPart {
  type:       'text' | 'image_url';
  text?:      string;
  image_url?: { url: string };
}

interface OllamaResponse {
  choices: Array<{ message: { content: string | null } }>;
}

interface WhisperVerboseJson {
  text:     string;
  language: string;
}

// ── Détection de transcriptions parasites ─────────────────────────────────────
// Gemini (si activé) et Whisper produisent parfois des séquences de timestamps
// SRT ("00:00 00:01 ...") sur audio silencieux.

const TIMESTAMP_RE = /^(?:\d{1,2}:\d{2}\s*)+$/;

function isGarbage(text: string): boolean {
  const t = text.trim();
  return t.length < 3 || TIMESTAMP_RE.test(t) || /^[\d\s:.,\-]+$/.test(t);
}

// ─────────────────────────────────────────────────────────────────────────────

@Injectable()
export class LocalStrategy implements IAiProvider {
  private readonly logger = new Logger(LocalStrategy.name);

  private readonly ollamaUrl:    string;
  private readonly ollamaModel:  string;
  private readonly ollamaTimeout: number;
  private readonly whisperUrl:   string;
  private readonly whisperModel: string;

  // Contexte réduit = moins de RAM + inférence plus rapide.
  // L'extraction d'intent n'a besoin que de ~600 tokens max.
  private static readonly NUM_CTX = 2048;

  constructor() {
    this.ollamaUrl     = process.env['OLLAMA_BASE_URL']   ?? 'http://ollama:11434';
    this.ollamaModel   = process.env['OLLAMA_MODEL']       ?? 'gemma4:e2b';
    this.ollamaTimeout = parseInt(process.env['OLLAMA_TIMEOUT_MS'] ?? '45000', 10);
    this.whisperUrl    = process.env['WHISPER_BASE_URL']  ?? 'http://whisper:8000';
    this.whisperModel  = process.env['WHISPER_MODEL']      ?? 'Systran/faster-whisper-small';

    this.logger.log(
      `✅ LocalStrategy (100% hors-ligne)\n` +
      `   ├─ texte/image : Ollama → ${this.ollamaModel}\n` +
      `   └─ audio       : faster-whisper → ${this.whisperModel}`,
    );
  }

  // ── Texte ──────────────────────────────────────────────────────────────────

  async generateText(
    prompt:       string,
    systemPrompt: string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    return this.chat([
      { role: 'system', content: systemPrompt },
      { role: 'user',   content: prompt },
    ], opts);
  }

  // ── Image (multimodal natif via gemma4) ────────────────────────────────────

  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const mime = this.detectImageMime(Buffer.from(imageBase64, 'base64'));

    return this.chat([{
      role:    'user',
      content: [
        { type: 'image_url', image_url: { url: `data:${mime};base64,${imageBase64}` } },
        { type: 'text',      text: prompt },
      ],
    }], opts);
  }

  // ── Audio (faster-whisper, API compatible OpenAI) ──────────────────────────

  async processAudio(
    buffer: Buffer,
    mime:   string,
    _opts:  { temperature?: number; maxTokens?: number } = {},
  ): Promise<AudioResult> {
    const normalizedMime = this.normalizeMime(mime);
    const ext            = this.mimeToExt(normalizedMime);

    const form = new FormData();
    form.append('file',            new Blob([new Uint8Array(buffer)], { type: normalizedMime }), `audio.${ext}`);
    form.append('model',           this.whisperModel);
    form.append('response_format', 'verbose_json');
    form.append('language',        'auto');
    // beam_size=1 → 2x plus rapide sur CPU, qualité légèrement réduite mais
    // suffisante pour des messages vocaux courts de 5-20 secondes.
    form.append('beam_size',       '1');

    const ctrl  = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 60_000);

    try {
      const res = await fetch(`${this.whisperUrl}/v1/audio/transcriptions`, {
        method: 'POST',
        body:   form,
        signal: ctrl.signal,
      });

      if (!res.ok) {
        throw new Error(`faster-whisper ${res.status}: ${await res.text().catch(() => res.statusText)}`);
      }

      const data = await res.json() as WhisperVerboseJson;
      const text = (data.text ?? '').trim();

      if (isGarbage(text)) {
        this.logger.debug(`Whisper: audio silencieux ou parasite — retourne vide`);
        return { text: '', language: data.language ?? 'auto' };
      }

      this.logger.debug(`Whisper [${data.language}]: ${text.slice(0, 80)}`);
      return { text, language: data.language ?? 'auto' };

    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        throw new Error(`faster-whisper timeout (60s) — le service est-il démarré ?`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  // ── Privé ──────────────────────────────────────────────────────────────────

  private async chat(
    messages: OllamaMessage[],
    opts: { temperature?: number; maxTokens?: number },
  ): Promise<string> {
    const ctrl  = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.ollamaTimeout);

    try {
      const res = await fetch(`${this.ollamaUrl}/v1/chat/completions`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        signal:  ctrl.signal,
        body: JSON.stringify({
          model:    this.ollamaModel,
          messages,
          stream:   false,
          options: {
            num_ctx: LocalStrategy.NUM_CTX,
            // Désactive le mode "thinking" — inutile pour JSON structuré
            // et multiplie les tokens consommés
            think:   false,
            seed:    42,
          },
          temperature: opts.temperature ?? 0.05,
          max_tokens:  opts.maxTokens   ?? 300,
        }),
      });

      if (!res.ok) {
        const body = await res.text().catch(() => res.statusText);
        if (res.status === 404) {
          throw new Error(
            `Modèle "${this.ollamaModel}" introuvable. ` +
            `Lancez : docker exec khidmeti-ollama ollama pull ${this.ollamaModel}`,
          );
        }
        throw new Error(`Ollama ${res.status}: ${body}`);
      }

      const data = await res.json() as OllamaResponse;
      return data.choices?.[0]?.message?.content ?? '';

    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        throw new Error(`Ollama timeout (${this.ollamaTimeout}ms) — CPU lent ou modèle non chargé`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  private detectImageMime(buf: Buffer): string {
    if (buf.length < 4) return 'image/jpeg';
    if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff)                        return 'image/jpeg';
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47)     return 'image/png';
    if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46)                        return 'image/gif';
    if (buf.length >= 12 &&
        buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
        buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50)   return 'image/webp';
    return 'image/jpeg';
  }

  private normalizeMime(mime: string): string {
    if (!mime || mime === 'application/octet-stream') return 'audio/mp4';
    const map: Record<string, string> = {
      'audio/x-wav':  'audio/wav',
      'audio/x-m4a':  'audio/mp4',
      'audio/mpeg':   'audio/mp3',
      'audio/x-mpeg': 'audio/mp3',
    };
    return map[mime] ?? mime;
  }

  private mimeToExt(mime: string): string {
    const map: Record<string, string> = {
      'audio/wav':  'wav', 'audio/mp3':  'mp3', 'audio/mp4':  'm4a',
      'audio/ogg':  'ogg', 'audio/flac': 'flac','audio/webm': 'webm','audio/aac': 'aac',
    };
    return map[mime] ?? 'wav';
  }
}
