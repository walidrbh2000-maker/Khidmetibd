// apps/api/src/modules/ai/providers/local.strategy.ts
// FIX v8 — Dual-model strategy : gemma3:1b (texte) + moondream (vision)
//
// POURQUOI deux modèles ?
//   gemma3:4b (3.6 GB chargé) + pic inférence = 6.5 GB → OOM kill systématique.
//
//   Solution : modèles spécialisés ultra-légers :
//   ┌──────────────┬──────────────────┬──────────┬─────────────────────────┐
//   │ Méthode      │ Modèle           │ RAM      │ Justification           │
//   ├──────────────┼──────────────────┼──────────┼─────────────────────────┤
//   │ generateText │ gemma3:1b        │ ~1.2 GB  │ JSON extraction Darija  │
//   │ analyzeImage │ moondream (1.9B) │ ~1.5 GB  │ edge vision model       │
//   │ processAudio │ faster-whisper   │ ~0.9 GB  │ inchangé                │
//   └──────────────┴──────────────────┴──────────┴─────────────────────────┘
//
//   OLLAMA_MAX_LOADED_MODELS=1 → swap automatique entre les deux modèles.
//   Un seul modèle en RAM à la fois. Swap time : ~5-10s (acceptable).
//
//   Budget mémoire total : 1.5 GB (vs 6.5 GB avant) → économie de 5 GB ✅
//   Ollama mem_limit : 8g → 3g ✅
//
// MOONDREAM — optimisé pour l'analyse de photos de sinistres :
//   - Conçu pour l'edge (Raspberry Pi, mobile, CPU-only)
//   - Répond à "describe this image" en 2-3s sur CPU
//   - Détecte : fuite d'eau, prise brûlée, dégât visible
//   - Taille : 1.9B / ~1.5 GB (vs gemma3:4b 3.6 GB)
//   - API OpenAI-compatible → même endpoint /v1/chat/completions
//
// GEMMA3:1B — extraction d'intention texte :
//   - Architecture Gemma 3 — même famille, support arabe/darija
//   - 1B paramètres → ~1.2 GB RAM chargé
//   - NUM_CTX=1024 suffit pour l'extraction JSON
//     (prompt system ~400 tokens + query ~100 + réponse JSON ~100)
//   - Latence CPU : ~3-5s (vs 10-15s pour 4b)
//
// PULL initial (une seule fois) :
//   make ollama-pull-all

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

interface OllamaErrorBody {
  error?: string;
}

interface WhisperVerboseJson {
  text:     string;
  language: string;
}

// ── Détection de transcriptions parasites ─────────────────────────────────────

const TIMESTAMP_RE = /^(?:\d{1,2}:\d{2}\s*)+$/;

function isGarbage(text: string): boolean {
  const t = text.trim();
  return t.length < 3 || TIMESTAMP_RE.test(t) || /^[\d\s:.,\-]+$/.test(t);
}

// ─────────────────────────────────────────────────────────────────────────────

@Injectable()
export class LocalStrategy implements IAiProvider {
  private readonly logger = new Logger(LocalStrategy.name);

  private readonly ollamaUrl:          string;
  private readonly ollamaModel:        string; // gemma3:1b — texte/JSON
  private readonly ollamaVisionModel:  string; // moondream  — images
  private readonly ollamaTimeout:      number;
  private readonly whisperUrl:         string;
  private readonly whisperModel:       string;

  // gemma3:1b : 1024 tokens suffisent
  // (prompt system ~400 + query ~100 + réponse JSON ~100)
  private static readonly NUM_CTX        = 1024;

  // moondream : davantage de tokens pour encoder les features visuelles
  private static readonly VISION_NUM_CTX = 2048;

  constructor() {
    this.ollamaUrl         = process.env['OLLAMA_BASE_URL']        ?? 'http://ollama:11434';
    this.ollamaModel       = process.env['OLLAMA_MODEL']            ?? 'gemma3:1b';
    this.ollamaVisionModel = process.env['OLLAMA_VISION_MODEL']     ?? 'moondream';
    this.ollamaTimeout     = parseInt(process.env['OLLAMA_TIMEOUT_MS'] ?? '60000', 10);
    this.whisperUrl        = process.env['WHISPER_BASE_URL']        ?? 'http://whisper:8000';
    this.whisperModel      = process.env['WHISPER_MODEL']           ?? 'Systran/faster-whisper-small';

    this.logger.log(
      `✅ LocalStrategy v8 — Dual-model (low RAM)\n` +
      `   ├─ texte  : Ollama → ${this.ollamaModel} (NUM_CTX=${LocalStrategy.NUM_CTX})\n` +
      `   ├─ image  : Ollama → ${this.ollamaVisionModel} (NUM_CTX=${LocalStrategy.VISION_NUM_CTX})\n` +
      `   └─ audio  : faster-whisper → ${this.whisperModel}`,
    );
  }

  // ── Texte (gemma3:1b) ──────────────────────────────────────────────────────

  async generateText(
    prompt:       string,
    systemPrompt: string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    return this.chat(
      this.ollamaModel,
      LocalStrategy.NUM_CTX,
      [
        { role: 'system', content: systemPrompt },
        { role: 'user',   content: prompt },
      ],
      opts,
    );
  }

  // ── Image (moondream — edge vision model) ──────────────────────────────────
  //
  // moondream supporte l'API OpenAI-compatible /v1/chat/completions avec images.
  // On lui envoie le prompt + l'image encodée en base64 via image_url.
  // VISION_NUM_CTX=2048 pour l'encodage des features visuelles.

  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const mime = this.detectImageMime(Buffer.from(imageBase64, 'base64'));

    return this.chat(
      this.ollamaVisionModel,
      LocalStrategy.VISION_NUM_CTX,
      [{
        role:    'user',
        content: [
          { type: 'image_url', image_url: { url: `data:${mime};base64,${imageBase64}` } },
          { type: 'text',      text: prompt },
        ],
      }],
      opts,
    );
  }

  // ── Audio (faster-whisper — inchangé) ──────────────────────────────────────
  //
  // FIX v6 : suppression du champ language='auto' (HTTP 422 — pas ISO 639-1).
  // FIX v7 : wrap fetch error → message clair pour OVERLOAD_PATTERNS.

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
    // NOTE : 'language' intentionnellement absent — 'auto' cause HTTP 422.
    form.append('beam_size',       '1');

    const ctrl  = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 60_000);

    try {
      let res: Response;
      try {
        res = await fetch(`${this.whisperUrl}/v1/audio/transcriptions`, {
          method: 'POST',
          body:   form,
          signal: ctrl.signal,
        });
      } catch (fetchErr) {
        const msg = fetchErr instanceof Error ? fetchErr.message : String(fetchErr);
        throw new Error(`Whisper fetch failed: ${msg}`);
      }

      if (!res.ok) {
        const body = await res.text().catch(() => res.statusText);
        throw new Error(`faster-whisper ${res.status}: ${body}`);
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
        throw new Error(`Whisper timeout (60s) — le service est-il démarré ?`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  // ── Privé — chat générique (modèle + ctx paramétrables) ───────────────────
  //
  // Centralise la logique HTTP commune aux deux modèles.
  // Paramètres :
  //   model   → ollamaModel (texte) ou ollamaVisionModel (image)
  //   numCtx  → NUM_CTX (1024) ou VISION_NUM_CTX (2048)
  //   messages → array OpenAI-compatible (avec ou sans image_url)
  //   opts    → temperature, maxTokens
  //
  // FIX v7 :
  //   - Extraction de l'error string interne du body JSON Ollama
  //     (ex: "llama runner process has terminated: %!w(<nil>)")
  //     pour que OVERLOAD_PATTERNS puisse le capturer.
  //   - Vérification explicite content !== null avant retour.

  private async chat(
    model:    string,
    numCtx:   number,
    messages: OllamaMessage[],
    opts:     { temperature?: number; maxTokens?: number },
  ): Promise<string> {
    const ctrl  = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), this.ollamaTimeout);

    try {
      let res: Response;
      try {
        res = await fetch(`${this.ollamaUrl}/v1/chat/completions`, {
          method:  'POST',
          headers: { 'Content-Type': 'application/json' },
          signal:  ctrl.signal,
          body: JSON.stringify({
            model,
            messages,
            stream:  false,
            options: { num_ctx: numCtx },
            temperature: opts.temperature ?? 0.05,
            max_tokens:  opts.maxTokens   ?? 200,
          }),
        });
      } catch (fetchErr) {
        const msg = fetchErr instanceof Error ? fetchErr.message : String(fetchErr);
        throw new Error(`Ollama fetch failed: ${msg}`);
      }

      if (!res.ok) {
        const rawBody = await res.text().catch(() => res.statusText);

        let internalError: string = rawBody;
        try {
          const parsed = JSON.parse(rawBody) as OllamaErrorBody;
          if (parsed.error && typeof parsed.error === 'string') {
            // Extraire la partie significative avant ": %!w(...)"
            internalError = parsed.error.split(':')[0].trim();
          }
        } catch { /* rawBody n'est pas du JSON valide */ }

        if (res.status === 404) {
          throw new Error(
            `Modèle "${model}" introuvable. ` +
            `Pull : docker exec khidmeti-ollama ollama pull ${model}`,
          );
        }
        throw new Error(`Ollama ${res.status}: ${internalError}`);
      }

      const data    = await res.json() as OllamaResponse;
      const content = data.choices?.[0]?.message?.content;

      if (!content || typeof content !== 'string') {
        throw new Error(`Ollama returned empty or null content — runner may be unstable`);
      }

      return content;

    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        throw new Error(
          `Ollama timeout (${this.ollamaTimeout}ms) — modèle: ${model}. ` +
          `CPU lent ou swap en cours. Vérifiez : make logs-ollama`,
        );
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  private detectImageMime(buf: Buffer): string {
    if (buf.length < 4) return 'image/jpeg';
    // JPEG : FF D8 FF
    if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff)
      return 'image/jpeg';
    // PNG : 89 50 4E 47
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47)
      return 'image/png';
    // GIF : 47 49 46
    if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46)
      return 'image/gif';
    // WebP : RIFF....WEBP
    if (
      buf.length >= 12 &&
      buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
      buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50
    )
      return 'image/webp';
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
