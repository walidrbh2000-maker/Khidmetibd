// apps/api/src/modules/ai/providers/local.strategy.ts
//
// v11 — Architecture directe llama.cpp:server (sans Ollama)
//
// ══════════════════════════════════════════════════════════════════════════════
// MIGRATION depuis Ollama :
//
//   AVANT (v10) :
//     Ollama (Go wrapper) → llama.cpp runner
//     PROBLÈME : "llama runner process has terminated: %w(<nil>)"
//     → Le wrapper Go d'Ollama est instable sur CPU limité
//     → Crash silencieux sans possibilité de redémarrage partiel
//     → 100+ MB RAM overhead pour le wrapper Go inutile
//
//   APRÈS (v11) :
//     llama.cpp:server (binaire C++ pur) via Docker
//     → Même engine, SANS le wrapper instable
//     → Démarrage ~3s (modèle déjà sur disque bind-mount)
//     → API OpenAI-compatible identique → zéro changement d'interface
//     → Mémoire exactement prévisible (pas de Go runtime)
//
// CHANGEMENTS v11 :
//
//   1. ollamaUrl       → http://ai-text:8011  (llama.cpp:server Qwen3-0.6B)
//      ollamaVisionUrl → http://ai-vision:8012 (llama.cpp:server moondream2)
//      whisperUrl      → http://ai-audio:8000  (faster-whisper large-v3-turbo)
//
//   2. chat() accepte baseUrl comme 1er paramètre (URL explicite par service)
//      → generateText() utilise ollamaUrl   (ai-text)
//      → analyzeImage() step-1 utilise ollamaVisionUrl (ai-vision)
//      → analyzeImage() step-2 utilise ollamaUrl (ai-text)
//
//   3. Qwen3 non-thinking mode :
//      → chat_template_kwargs: { thinking_budget: 0 }
//      → Strip automatique des balises <think>...</think> en post-processing
//      → Garantit JSON immédiat sans chain-of-thought
//
//   4. Timeouts réduits (plus de Go overhead) :
//      ollamaTimeout       : 60 000ms → 15 000ms  (Qwen3-0.6B rapide)
//      ollamaVisionTimeout : 150 000ms → 60 000ms (moondream direct)
//
// PIPELINE TWO-STEP (conservé depuis v10, maintenant plus stable) :
//
//   Step 1 : moondream2 via ai-vision:8012
//            → "Describe this home appliance problem in one sentence in English."
//            → Output : description en anglais (moondream excelle à ça)
//            → Pas de JSON, pas de schema, pas d'instructions complexes
//
//   Step 2 : Qwen3-0.6B via ai-text:8011
//            → Input : description de step-1
//            → Output : JSON intent structuré (Qwen3 suit les instructions)
//            → Mode non-thinking activé = JSON immédiat
//
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

// ── Nettoyage des réponses IA ─────────────────────────────────────────────────

/**
 * Supprime les blocs de "thinking" des modèles qui les génèrent :
 *  - Qwen3 : <think>...</think>
 *  - Anciens Ollama : <|channel>thought...<channel|>
 *  - Markdown code blocks : ```json...```
 */
function cleanAiResponse(raw: string): string {
  return raw
    .replace(/<think>[\s\S]*?<\/think>/gi, '')            // Qwen3 thinking
    .replace(/<\|channel>thought[\s\S]*?<channel\|>/g, '') // Ollama thought
    .replace(/```(?:json)?\s*/g, '')                       // markdown code
    .replace(/```/g, '')
    .trim();
}

// ─────────────────────────────────────────────────────────────────────────────

@Injectable()
export class LocalStrategy implements IAiProvider {
  private readonly logger = new Logger(LocalStrategy.name);

  // ── Endpoints ────────────────────────────────────────────────────────────────

  /** URL du service texte/JSON : llama.cpp:server + Qwen3-0.6B */
  private readonly ollamaUrl:           string;

  /**
   * URL du service vision : llama.cpp:server + moondream2
   * Séparé de ollamaUrl pour l'isolation des pannes :
   * un crash vision n'affecte PAS les requêtes texte/audio.
   */
  private readonly ollamaVisionUrl:     string;

  private readonly ollamaModel:         string; // Qwen3-0.6B — texte/JSON
  private readonly ollamaVisionModel:   string; // moondream2  — description image

  /** Timeout pour les requêtes texte (Qwen3-0.6B rapide sur CPU) */
  private readonly ollamaTimeout:       number;

  /** Timeout pour les requêtes vision (moondream2 + CLIP encode) */
  private readonly ollamaVisionTimeout: number;

  private readonly whisperUrl:          string;
  private readonly whisperModel:        string;

  // ── Contextes KV-cache ────────────────────────────────────────────────────
  // Qwen3-0.6B : 512 tokens suffisent (system ~300 + query ~100 + JSON ~100)
  private static readonly NUM_CTX        = 512;

  // moondream2 : 1024 tokens pour l'encodage CLIP + génération description
  private static readonly VISION_NUM_CTX = 1024;

  constructor() {
    // ── v11 : URLs directes llama.cpp:server (plus Ollama) ──────────────────
    this.ollamaUrl           = process.env['OLLAMA_BASE_URL']              ?? 'http://ai-text:8011';
    this.ollamaVisionUrl     = process.env['OLLAMA_BASE_URL_VISION']       ?? 'http://ai-vision:8012';
    this.ollamaModel         = process.env['OLLAMA_MODEL']                  ?? 'qwen3-0.6b-q4_k_m';
    this.ollamaVisionModel   = process.env['OLLAMA_VISION_MODEL']           ?? 'moondream2';

    // v11 : timeouts réduits — plus de Go wrapper overhead
    this.ollamaTimeout       = parseInt(process.env['OLLAMA_TIMEOUT_MS']         ?? '15000', 10);
    this.ollamaVisionTimeout = parseInt(process.env['OLLAMA_VISION_TIMEOUT_MS']  ?? '60000', 10);

    this.whisperUrl          = process.env['WHISPER_BASE_URL']             ?? 'http://ai-audio:8000';
    this.whisperModel        = process.env['WHISPER_MODEL']                 ?? 'Systran/faster-whisper-large-v3-turbo';

    this.logger.log(
      `✅ LocalStrategy v11 — llama.cpp:server direct (sans Ollama)\n` +
      `   ├─ texte  : ${this.ollamaUrl} → ${this.ollamaModel}` +
      `       (CTX=${LocalStrategy.NUM_CTX}, timeout=${this.ollamaTimeout}ms)\n` +
      `   ├─ vision : ${this.ollamaVisionUrl} → ${this.ollamaVisionModel}` +
      `  (CTX=${LocalStrategy.VISION_NUM_CTX}, timeout=${this.ollamaVisionTimeout}ms)\n` +
      `   └─ audio  : ${this.whisperUrl} → ${this.whisperModel}`,
    );
  }

  // ── Texte / JSON (Qwen3-0.6B via ai-text:8011) ────────────────────────────

  async generateText(
    prompt:       string,
    systemPrompt: string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    return this.chat(
      this.ollamaUrl,
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

  // ── Vision — Two-Step Pipeline ─────────────────────────────────────────────
  //
  // v11 : même pipeline two-step qu'en v10, mais maintenant chaque step
  // cible un service llama.cpp:server indépendant et stable.
  //
  // POURQUOI le two-step est toujours nécessaire avec moondream2 ?
  //   moondream2 excelle à décrire des images en anglais (c'est son job).
  //   Il ne suit PAS les instructions JSON/structured output — jamais.
  //   → Step 1 : moondream2 décrit  (ce qu'il sait faire)
  //   → Step 2 : Qwen3 extrait JSON (ce qu'il sait faire)
  //
  // NOTE sur `prompt` (paramètre IAiProvider.analyzeImage) :
  //   intent-extractor.service.ts passe SYSTEM_PROMPT + preamble.
  //   On l'utilise comme system message pour step-2 (Qwen3).
  //   Step-1 (moondream) reçoit uniquement l'image + instruction simple.

  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const mime = this.detectImageMime(Buffer.from(imageBase64, 'base64'));

    // ── Step 1 : moondream2 — description visuelle pure ──────────────────────
    // Instruction volontairement simple : pas de JSON, pas de schema.
    // moondream2 est optimisé pour la description d'objets/scènes, pas pour
    // suivre des instructions complexes.
    let description: string;
    try {
      description = await this.chat(
        this.ollamaVisionUrl,
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
      // Re-throw pour que le circuit breaker 'image' dans intent-extractor
      // enregistre correctement l'échec. Ne pas avaler l'erreur.
      throw err;
    }

    this.logger.debug(`[vision step-1] moondream2: "${description.trim().slice(0, 120)}"`);

    // ── Step 2 : Qwen3 — extraction JSON d'intent ────────────────────────────
    // `prompt` contient SYSTEM_PROMPT avec few-shot examples.
    // Qwen3 mode non-thinking → JSON immédiat (pas de chain-of-thought).
    return this.chat(
      this.ollamaUrl,
      this.ollamaModel,
      LocalStrategy.NUM_CTX,
      this.ollamaTimeout,
      [
        { role: 'system', content: prompt },
        { role: 'user',   content: `Image shows: ${description.trim()}` },
      ],
      { temperature: opts.temperature ?? 0.05, maxTokens: opts.maxTokens ?? 200 },
    );
  }

  // ── Audio (faster-whisper-large-v3-turbo via ai-audio:8000) ───────────────

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
    // WHISPER__LANGUAGE=fr est configuré côté serveur (docker-compose.yml)
    // → améliore la Darija algérienne (~40% vocabulaire français partagé)
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
        this.logger.debug(`Whisper: audio silencieux ou parasite → retourne vide`);
        return { text: '', language: data.language ?? 'auto' };
      }

      this.logger.debug(`Whisper [${data.language}]: ${text.slice(0, 80)}`);
      return { text, language: data.language ?? 'auto' };

    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        throw new Error(`Whisper timeout (60s) — le service ai-audio est-il démarré ?`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  // ── Privé — chat générique ─────────────────────────────────────────────────
  //
  // v11 : baseUrl est le 1er paramètre (URL explicite)
  //   → generateText() passe ollamaUrl    (ai-text:8011)
  //   → analyzeImage() step-1 passe ollamaVisionUrl (ai-vision:8012)
  //   → analyzeImage() step-2 passe ollamaUrl    (ai-text:8011)
  //
  // QWEN3 NON-THINKING MODE :
  //   Qwen3 a un mode "thinking" (chain-of-thought) qui produit des blocs
  //   <think>...</think> avant la réponse JSON. Sur un modèle 0.6B, cela
  //   peut représenter 200-500 tokens inutiles qui ralentissent l'inférence
  //   et consomment le context window.
  //   Désactivation via :
  //     1. chat_template_kwargs: { thinking_budget: 0 } (llama.cpp >= b3900)
  //     2. cleanAiResponse() supprime les balises <think> résiduelles
  //
  // llama.cpp vs Ollama — différences API :
  //   llama.cpp ignore les clés inconnues (options.num_ctx, etc.) → safe
  //   llama.cpp retourne exactement choices[0].message.content → identique

  private async chat(
    baseUrl:   string,
    model:     string,
    numCtx:    number,
    timeoutMs: number,
    messages:  OllamaMessage[],
    opts:      { temperature?: number; maxTokens?: number },
  ): Promise<string> {
    const ctrl  = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);

    // Détection Qwen3 pour le mode non-thinking
    const isQwen3 = model.toLowerCase().includes('qwen3') ||
                    model.toLowerCase().includes('qwen-3');

    try {
      let res: Response;
      try {
        res = await fetch(`${baseUrl}/v1/chat/completions`, {
          method:  'POST',
          headers: { 'Content-Type': 'application/json' },
          signal:  ctrl.signal,
          body: JSON.stringify({
            model,
            messages,
            stream:      false,
            temperature: opts.temperature ?? 0.05,
            max_tokens:  opts.maxTokens   ?? 200,
            // Paramètres llama.cpp (ignorés si non supportés)
            cache_prompt: false,
            // Qwen3 non-thinking mode : désactive chain-of-thought
            // Supporté par llama.cpp >= b3900 avec le chat template Qwen3
            ...(isQwen3 ? {
              chat_template_kwargs: { thinking_budget: 0 },
            } : {}),
          }),
        });
      } catch (fetchErr) {
        if ((fetchErr as Error).name === 'AbortError') throw fetchErr;
        const msg = fetchErr instanceof Error ? fetchErr.message : String(fetchErr);
        throw new Error(`llama.cpp fetch failed [${baseUrl}]: ${msg}`);
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
            `Modèle "${model}" introuvable sur ${baseUrl}. ` +
            `Vérifiez que le fichier GGUF est dans docker/models/ et que ` +
            `le container est démarré.`,
          );
        }
        throw new Error(`llama.cpp ${res.status} [${baseUrl}]: ${internalError}`);
      }

      const data    = await res.json() as OllamaResponse;
      const content = data.choices?.[0]?.message?.content;

      if (!content || typeof content !== 'string') {
        throw new Error(`llama.cpp returned empty content [${baseUrl}] — vérifiez le modèle chargé`);
      }

      // Nettoyage post-processing :
      // - Supprime les balises <think>...</think> de Qwen3
      // - Supprime les markdown code blocks
      // - Supprime les balises Ollama résiduelles
      return cleanAiResponse(content);

    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        throw new Error(
          `llama.cpp timeout (${timeoutMs}ms) [${baseUrl}] — modèle: ${model}. ` +
          `Vérifiez que le container est démarré : docker ps | grep ai-`,
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
