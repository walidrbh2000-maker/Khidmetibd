// apps/api/src/modules/ai/providers/local.strategy.ts
//
// FIX v10 — Two-Step Vision Pipeline (BREAKING FIX for image intent extraction)
//
// ══════════════════════════════════════════════════════════════════════════════
// PROBLEM (confirmed in logs — Images 6, 7, 8) :
//
//   [Nest] WARN [IntentExtractorService] Could not find JSON in AI response:
//   The image shows a white electrical outlet with a burnt-out plug on it...
//
//   ROOT CAUSE :
//     moondream is a lightweight vision model designed for edge devices.
//     Its documentation explicitly states it may struggle with complex or
//     precise instructions. It is a DESCRIPTION model, not an
//     instruction-following model. Sending it a JSON system prompt is ignored
//     entirely — it always outputs plain English prose.
//
//   CONSEQUENCE :
//     parse() finds no { } in the response → returns FALLBACK every time.
//     circuitImage.onSuccess() is still called (no exception thrown) so the
//     circuit never opens. Every image call silently returns confidence=0.
//
// FIX v10 — Two-Step Pipeline :
//
//   STEP 1 : moondream — pure visual description
//     Input  : base64 image
//     Prompt : "Describe this home appliance problem in one sentence in English."
//     Output : plain English sentence  (moondream is excellent at this)
//     Timeout: ollamaVisionTimeout (150 000 ms default)
//
//   STEP 2 : gemma3:1b — JSON intent extraction
//     Input  : the description from step 1
//     Prompt : SYSTEM_PROMPT (full JSON schema + few-shot examples)
//     Output : valid JSON intent object
//     Timeout: ollamaTimeout (60 000 ms)
//
//   This completely decouples the visual perception concern from the
//   structured-output concern. Each model does exactly what it was built for.
//
// ══════════════════════════════════════════════════════════════════════════════
// FIX v9 (maintained) — Separate timeouts per modality :
//
//   OLLAMA_TIMEOUT_MS        = 60 000 ms  (text   — gemma3:1b — fast)
//   OLLAMA_VISION_TIMEOUT_MS = 150 000 ms (vision — moondream — slow on CPU)
//
// FIX v9 (maintained) — AbortError detection bug :
//
//   Inner catch re-throws AbortError unmodified so the outer handler
//   correctly identifies timeouts via name === 'AbortError'.
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
  private readonly ollamaVisionModel:   string; // moondream  — description visuelle
  private readonly ollamaTimeout:       number; // timeout texte  (défaut 60 000 ms)
  private readonly ollamaVisionTimeout: number; // timeout vision (défaut 150 000 ms)
  private readonly whisperUrl:          string;
  private readonly whisperModel:        string;

  // gemma3:1b : 1024 tokens suffisent (system ~400 + query ~100 + réponse JSON ~100)
  private static readonly NUM_CTX        = 1024;

  // moondream : contexte plus large pour l'encodage CLIP des features visuelles.
  // En step 1 (description seulement), 512 tokens suffisent amplement — moondream
  // ne génère qu'une phrase courte. 1024 réduit le KV-cache et accélère l'inférence
  // de ~10-15% par rapport à 2048 sur CPU.
  private static readonly VISION_NUM_CTX = 1024;

  constructor() {
    this.ollamaUrl           = process.env['OLLAMA_BASE_URL']              ?? 'http://ollama:11434';
    this.ollamaModel         = process.env['OLLAMA_MODEL']                  ?? 'gemma3:1b';
    this.ollamaVisionModel   = process.env['OLLAMA_VISION_MODEL']           ?? 'moondream';
    this.ollamaTimeout       = parseInt(process.env['OLLAMA_TIMEOUT_MS']         ?? '60000',  10);
    this.ollamaVisionTimeout = parseInt(process.env['OLLAMA_VISION_TIMEOUT_MS']  ?? '150000', 10);
    this.whisperUrl          = process.env['WHISPER_BASE_URL']             ?? 'http://whisper:8000';
    this.whisperModel        = process.env['WHISPER_MODEL']                 ?? 'Systran/faster-whisper-small';

    this.logger.log(
      `✅ LocalStrategy v10 — Two-Step Vision Pipeline\n` +
      `   ├─ texte  : Ollama → ${this.ollamaModel}       (NUM_CTX=${LocalStrategy.NUM_CTX}, timeout=${this.ollamaTimeout}ms)\n` +
      `   ├─ vision : Ollama → ${this.ollamaVisionModel} (NUM_CTX=${LocalStrategy.VISION_NUM_CTX}, timeout=${this.ollamaVisionTimeout}ms) [step-1: describe]\n` +
      `   ├─         Ollama → ${this.ollamaModel}        (NUM_CTX=${LocalStrategy.NUM_CTX}, timeout=${this.ollamaTimeout}ms) [step-2: JSON]\n` +
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
      this.ollamaTimeout,
      [
        { role: 'system', content: systemPrompt },
        { role: 'user',   content: prompt },
      ],
      opts,
    );
  }

  // ── Image — Two-Step Pipeline ──────────────────────────────────────────────
  //
  // FIX v10 — Architecture change: moondream → description, gemma3:1b → JSON
  //
  // WHY this is necessary:
  //   moondream was designed for edge devices and optimised for image captioning.
  //   It does NOT follow structured output instructions (system prompts, JSON
  //   schemas, few-shot examples). Every attempt to get JSON from moondream
  //   silently fails — it returns plain English and parse() returns FALLBACK.
  //
  // HOW the two-step works:
  //   Step 1  moondream receives ONLY the image + a simple "describe in one
  //           sentence" prompt. This is exactly what moondream excels at.
  //           No JSON. No schema. No few-shot examples.
  //           Timeout: ollamaVisionTimeout (150s for cold-start on 8GB CPU).
  //
  //   Step 2  gemma3:1b receives the plain-text description as user message
  //           and the full SYSTEM_PROMPT (with JSON schema + few-shot) as the
  //           system message. gemma3:1b reliably produces valid JSON.
  //           Timeout: ollamaTimeout (60s — no image encoding needed).
  //
  // NOTE on the `prompt` parameter:
  //   intent-extractor.service.ts passes the SYSTEM_PROMPT concatenated with
  //   a preamble. We use it as-is as the system message for step 2, so the
  //   full few-shot context is preserved.
  //
  // NOTE on OLLAMA_MAX_LOADED_MODELS:
  //   With the default value of 1, Ollama swaps moondream ↔ gemma3:1b between
  //   steps. Swap time ≈ 5-10s on 8GB RAM. This is acceptable for image
  //   analysis (total latency ≈ vision_time + swap + json_time).
  //   With OLLAMA_MAX_LOADED_MODELS=2 (16GB+) both models stay in RAM and
  //   the swap is eliminated entirely.

  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const mime = this.detectImageMime(Buffer.from(imageBase64, 'base64'));

    // ── Step 1 : moondream — pure visual description ─────────────────────────
    // Intentionally simple prompt: no JSON, no schema, no instructions.
    // moondream handles this reliably and quickly.
    let description: string;
    try {
      description = await this.chat(
        this.ollamaVisionModel,
        LocalStrategy.VISION_NUM_CTX,
        this.ollamaVisionTimeout,
        [{
          role:    'user',
          content: [
            {
              type:      'image_url',
              image_url: { url: `data:${mime};base64,${imageBase64}` },
            },
            {
              type: 'text',
              text: 'Describe this home appliance or household problem in one sentence in English.',
            },
          ],
        }],
        { temperature: 0, maxTokens: 100 },
      );
    } catch (err) {
      // Re-throw so intent-extractor circuit breaker handles it correctly.
      // Do NOT swallow — a timeout here should count as an image circuit failure.
      throw err;
    }

    this.logger.debug(`[vision step-1] moondream: "${description.trim().slice(0, 120)}"`);

    // ── Step 2 : gemma3:1b — JSON intent extraction from the description ─────
    // The `prompt` parameter already contains SYSTEM_PROMPT + few-shot examples.
    // We use it as the system message so gemma3:1b has full extraction context.
    return this.chat(
      this.ollamaModel,
      LocalStrategy.NUM_CTX,
      this.ollamaTimeout,
      [
        { role: 'system', content: prompt },
        { role: 'user',   content: `Image shows: ${description.trim()}` },
      ],
      { temperature: opts.temperature ?? 0.05, maxTokens: opts.maxTokens ?? 256 },
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
    // Le docker-compose définit WHISPER__LANGUAGE=fr pour améliorer la
    // reconnaissance de la Darija algérienne (fortement influencée par le français).
    form.append('beam_size', '1');

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
        // swallowed as a generic "Whisper fetch failed" error.
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

  // ── Privé — chat générique ─────────────────────────────────────────────────
  //
  // Paramètres :
  //   model     : nom du modèle Ollama (gemma3:1b ou moondream)
  //   numCtx    : taille du contexte KV-cache
  //   timeoutMs : timeout indépendant par modalité (FIX v9)
  //   messages  : historique de conversation (avec support multimodal)
  //   opts      : temperature / maxTokens
  //
  // FIX v9 — correction du bug AbortError :
  //   AbortError est re-throw avant d'être wrappé en Error générique,
  //   garantissant que name === 'AbortError' est préservé jusqu'au catch externe.

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
        // FIX v9 : Re-throw AbortError unmodified so the outer catch receives
        // it with name === 'AbortError' intact. Without this, AbortError was
        // wrapped as a plain Error and the timeout message was lost.
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
