// apps/api/src/modules/ai/providers/local.strategy.ts
// FIX v9 — Three critical fixes for 8 GB RAM environments
//
// ══════════════════════════════════════════════════════════════════════════════
// FIX 1 — Vision timeout too short (CRITICAL)
//
//   SYMPTOM : [GIN] | 500 | 1m0s  →  "Ollama fetch failed: This operation was aborted"
//
//   ROOT CAUSE — moondream inference on 8 GB CPU :
//     model cold-start  :  ~11 seconds
//     CLIP encoding     :  ~20-40 seconds  (378×378 image → 729 vision tokens)
//     text generation   :  ~10-20 seconds
//     ────────────────────────────────────
//     total (cold)      :  ~41-71 seconds  >  OLLAMA_TIMEOUT_MS=60000 ❌
//
//   FIX : Introduce OLLAMA_VISION_TIMEOUT_MS (default 150 000 ms = 2.5 min).
//         Text inference (gemma3:1b) keeps OLLAMA_TIMEOUT_MS (60 000 ms).
//
// ══════════════════════════════════════════════════════════════════════════════
// FIX 2 — AbortError detection bug
//
//   SYMPTOM : Timeout displayed as "Ollama fetch failed: This operation was aborted"
//             instead of the clear "Ollama timeout (Xms) — modèle: moondream" message.
//
//   ROOT CAUSE :
//     Inner catch wraps ANY fetch exception — including AbortError — as a
//     plain Error before the outer catch can test name === 'AbortError' :
//
//       try {                                          ← outer
//         try {
//           res = await fetch(..., { signal });
//         } catch (fetchErr) {
//           throw new Error(`Ollama fetch failed: ${msg}`);  ← wraps AbortError
//         }
//       } catch (err) {
//         if (err.name === 'AbortError') { ... }  ← NEVER REACHED (wrapped above)
//       }
//
//   FIX : Re-throw AbortError unmodified from the inner catch so the outer
//         handler receives it with name === 'AbortError' intact.
//
// ══════════════════════════════════════════════════════════════════════════════
// FIX 3 — Same AbortError bug in processAudio() — same fix applied.
// ══════════════════════════════════════════════════════════════════════════════

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

  private readonly ollamaUrl:           string;
  private readonly ollamaModel:         string; // gemma3:1b  — texte/JSON
  private readonly ollamaVisionModel:   string; // moondream  — images
  private readonly ollamaTimeout:       number; // timeout texte  (défaut 60 000 ms)
  private readonly ollamaVisionTimeout: number; // FIX v9 : timeout vision (défaut 150 000 ms)
  private readonly whisperUrl:          string;
  private readonly whisperModel:        string;

  // gemma3:1b : 1024 tokens suffisent (system ~400 + query ~100 + réponse JSON ~100)
  private static readonly NUM_CTX        = 1024;

  // moondream : contexte plus large pour l'encodage CLIP des features visuelles
  private static readonly VISION_NUM_CTX = 2048;

  constructor() {
    this.ollamaUrl           = process.env['OLLAMA_BASE_URL']              ?? 'http://ollama:11434';
    this.ollamaModel         = process.env['OLLAMA_MODEL']                  ?? 'gemma3:1b';
    this.ollamaVisionModel   = process.env['OLLAMA_VISION_MODEL']           ?? 'moondream';
    this.ollamaTimeout       = parseInt(process.env['OLLAMA_TIMEOUT_MS']         ?? '60000',  10);
    this.ollamaVisionTimeout = parseInt(process.env['OLLAMA_VISION_TIMEOUT_MS']  ?? '150000', 10);
    this.whisperUrl          = process.env['WHISPER_BASE_URL']             ?? 'http://whisper:8000';
    this.whisperModel        = process.env['WHISPER_MODEL']                 ?? 'Systran/faster-whisper-small';

    this.logger.log(
      `✅ LocalStrategy v9 — Dual-model (low RAM)\n` +
      `   ├─ texte  : Ollama → ${this.ollamaModel} (NUM_CTX=${LocalStrategy.NUM_CTX}, timeout=${this.ollamaTimeout}ms)\n` +
      `   ├─ image  : Ollama → ${this.ollamaVisionModel} (NUM_CTX=${LocalStrategy.VISION_NUM_CTX}, timeout=${this.ollamaVisionTimeout}ms)\n` +
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
      this.ollamaTimeout,   // timeout texte : 60 s
      [
        { role: 'system', content: systemPrompt },
        { role: 'user',   content: prompt },
      ],
      opts,
    );
  }

  // ── Image (moondream) ──────────────────────────────────────────────────────
  //
  // FIX v9 : utilise ollamaVisionTimeout (150 s par défaut).
  //
  // Sur CPU 8 GB, moondream cold-start (11 s) + CLIP encoding (~30-40 s) +
  // génération (~15 s) ≈ 56-66 s — dépasse systématiquement le timeout de 60 s.
  // Avec 150 s, même les cold-starts les plus lents passent confortablement.

  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const mime = this.detectImageMime(Buffer.from(imageBase64, 'base64'));

    return this.chat(
      this.ollamaVisionModel,
      LocalStrategy.VISION_NUM_CTX,
      this.ollamaVisionTimeout,  // FIX v9 : timeout vision : 150 s
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

  // ── Audio (faster-whisper) ─────────────────────────────────────────────────
  //
  // FIX v6 : language='auto' supprimé (HTTP 422 — code non ISO 639-1).
  // FIX v7 : wrap des erreurs réseau pour OVERLOAD_PATTERNS.
  // FIX v9 : correction du bug AbortError → re-throw avant wrapping.

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
        // FIX v9 : Re-throw AbortError unmodified — prevents it from being
        // swallowed as a generic "Whisper fetch failed" error. The outer catch
        // then correctly identifies it as a timeout.
        if ((fetchErr as Error).name === 'AbortError') throw fetchErr;

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

  // ── Privé — chat générique (modèle + ctx + timeout paramétrables) ──────────
  //
  // FIX v9 — ajout du paramètre `timeoutMs` :
  //   Permet à generateText (60 s) et analyzeImage (150 s) d'avoir des
  //   timeouts indépendants sans dupliquer la logique HTTP.
  //
  // FIX v9 — correction du bug AbortError (voir header du fichier).
  //
  // FIX v7 maintenu — extraction error string interne du JSON Ollama :
  //   { "error": "llama runner process has terminated: %!w(<nil>)" }
  //   → extrait "llama runner process has terminated" pour OVERLOAD_PATTERNS.

  private async chat(
    model:     string,
    numCtx:    number,
    timeoutMs: number,
    messages:  OllamaMessage[],
    opts:      { temperature?: number; maxTokens?: number },
  ): Promise<string> {
    const ctrl  = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);

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
        // FIX v9 : Re-throw AbortError unmodified so the outer catch receives it
        // with name === 'AbortError' intact. Without this, AbortError was wrapped
        // as a plain Error and the outer check never fired — producing the
        // confusing "Ollama fetch failed: This operation was aborted" message
        // visible in the logs at [GIN] | 500 | 1m0s.
        if ((fetchErr as Error).name === 'AbortError') throw fetchErr;

        const msg = fetchErr instanceof Error ? fetchErr.message : String(fetchErr);
        throw new Error(`Ollama fetch failed: ${msg}`);
      }

      if (!res.ok) {
        const rawBody = await res.text().catch(() => res.statusText);

        let internalError: string = rawBody;
        try {
          const parsed = JSON.parse(rawBody) as OllamaErrorBody;
          if (parsed.error && typeof parsed.error === 'string') {
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
        // FIX v9 : Now correctly reached thanks to the inner-catch fix above
        throw new Error(
          `Ollama timeout (${timeoutMs}ms) — modèle: ${model}. ` +
          `Sur CPU 8 GB, la vision peut prendre jusqu'à 90s (cold-start). ` +
          `Augmentez OLLAMA_VISION_TIMEOUT_MS si nécessaire.`,
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
    if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff)
      return 'image/jpeg';
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47)
      return 'image/png';
    if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46)
      return 'image/gif';
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
