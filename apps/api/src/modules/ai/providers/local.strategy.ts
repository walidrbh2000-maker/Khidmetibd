// apps/api/src/modules/ai/providers/local.strategy.ts
//
// Backend IA 100% local — aucune dépendance externe.
//
// ┌──────────────┬──────────────────────────────────────┬─────────────────┐
// │ Méthode      │ Service                              │ RAM (CPU)       │
// ├──────────────┼──────────────────────────────────────┼─────────────────┤
// │ generateText │ Ollama → gemma3:4b                   │ ~3.5 GB chargé  │
// │ analyzeImage │ Ollama → gemma3:4b (multimodal)      │ partagé         │
// │ processAudio │ faster-whisper → small int8 CPU      │ ~500 MB fixe    │
// └──────────────┴──────────────────────────────────────┴─────────────────┘
//
// FIX v6 — Suppression de language:'auto' dans processAudio() :
//   'auto' n'est pas un code ISO 639-1 valide → HTTP 422 Unprocessable Entity.
//
// FIX v7 — Amélioration de la détection d'erreurs :
//
//   PROBLÈME 1 : Quand le runner Ollama crashe (OOM kill par le cgroup Docker),
//     il renvoie une 500 dont le body est :
//       {"error":"llama runner process has terminated: %!w(<nil>)"}
//     Le `%!w(<nil>)` est un artefact Go fmt.Sprintf(nil) — le message brut
//     ne contenait AUCUN pattern reconnu par OVERLOAD_PATTERNS, causant un
//     return FALLBACK silencieux au lieu d'un HTTP 503 clair vers Flutter.
//
//   SOLUTION 1 : La méthode chat() extrait désormais l'error string interne
//     du body JSON Ollama pour exposer "llama runner process has terminated"
//     dans l'Error.message, permettant à OVERLOAD_PATTERNS de le capturer.
//
//   PROBLÈME 2 : fetch() lève "TypeError: fetch failed" quand Whisper est
//     en cours de redémarrage (exit 137). Ce message n'était pas non plus
//     reconnu, causant un FALLBACK silencieux.
//
//   SOLUTION 2 : La même extraction d'erreur dans processAudio() avec un
//     message clair "Whisper fetch failed" → capturé par OVERLOAD_PATTERNS.
//
//   PROBLÈME 3 : data.choices?.[0]?.message?.content pouvait être `null`
//     (Ollama renvoie null content quand le runner est instable) — la méthode
//     retournait la chaîne 'null' que parse() tentait de désérialiser en JSON.
//
//   SOLUTION 3 : Vérification explicite du content non-vide avant de retourner.

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

// FIX v7 : Interface pour parser le body d'erreur Ollama.
// Quand le runner crash, Ollama renvoie { "error": "llama runner process has terminated: ..." }
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

// ── Helper : sleep ────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ─────────────────────────────────────────────────────────────────────────────

@Injectable()
export class LocalStrategy implements IAiProvider {
  private readonly logger = new Logger(LocalStrategy.name);

  private readonly ollamaUrl:     string;
  private readonly ollamaModel:   string;
  private readonly ollamaTimeout: number;
  private readonly whisperUrl:    string;
  private readonly whisperModel:  string;

  // Aligné sur OLLAMA_NUM_CTX=2048 dans docker-compose.yml (FIX v6/v7).
  // 2048 est nécessaire pour l'analyse d'image (vision tokens + system prompt).
  private static readonly NUM_CTX = 2048;

  constructor() {
    this.ollamaUrl     = process.env['OLLAMA_BASE_URL']    ?? 'http://ollama:11434';
    this.ollamaModel   = process.env['OLLAMA_MODEL']        ?? 'gemma3:4b';
    this.ollamaTimeout = parseInt(process.env['OLLAMA_TIMEOUT_MS'] ?? '120000', 10);
    this.whisperUrl    = process.env['WHISPER_BASE_URL']   ?? 'http://whisper:8000';
    this.whisperModel  = process.env['WHISPER_MODEL']       ?? 'Systran/faster-whisper-small';

    this.logger.log(
      `✅ LocalStrategy (100% hors-ligne)\n` +
      `   ├─ texte/image : Ollama → ${this.ollamaModel} (NUM_CTX=${LocalStrategy.NUM_CTX})\n` +
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

  // ── Image (multimodal natif via gemma3:4b) ─────────────────────────────────

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
  //
  // FIX v6 — Suppression du champ language='auto' (HTTP 422).
  // FIX v7 — Extraction du message d'erreur réseau pour OVERLOAD_PATTERNS.
  //
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
        // FIX v7 : Convertir l'erreur réseau en message clair pour OVERLOAD_PATTERNS.
        // "fetch failed" ou "ECONNREFUSED" → reconnu par le circuit breaker.
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

  // ── Privé ──────────────────────────────────────────────────────────────────

  // FIX v7 : Extraction de l'error string interne du body JSON Ollama.
  //
  // AVANT : si Ollama retourne { "error": "llama runner process has terminated: %!w(<nil>)" }
  //   → throw new Error(`Ollama 500: {"error":"...%!w(<nil>)..."}`)
  //   → message capturé par NestJS mais ne matche AUCUN OVERLOAD_PATTERN
  //   → intent-extractor retourne FALLBACK silencieux (confidence=0)
  //   → Flutter croit que la requête a réussi mais sans résultat
  //
  // APRÈS : on parse le body JSON et on extrait l'error string interne :
  //   → throw new Error(`Ollama 500: llama runner process has terminated`)
  //   → matche /runner process has terminated/i dans OVERLOAD_PATTERNS
  //   → intent-extractor lève AiProviderException (HTTP 503)
  //   → Flutter sait qu'il doit réessayer
  //
  private async chat(
    messages: OllamaMessage[],
    opts: { temperature?: number; maxTokens?: number },
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
            model:    this.ollamaModel,
            messages,
            stream:   false,
            options: {
              num_ctx: LocalStrategy.NUM_CTX,
            },
            temperature: opts.temperature ?? 0.05,
            max_tokens:  opts.maxTokens   ?? 300,
          }),
        });
      } catch (fetchErr) {
        // FIX v7 : Erreur réseau (ECONNREFUSED, fetch failed, etc.)
        const msg = fetchErr instanceof Error ? fetchErr.message : String(fetchErr);
        throw new Error(`Ollama fetch failed: ${msg}`);
      }

      if (!res.ok) {
        // FIX v7 : Extraire l'error string interne du JSON Ollama.
        // { "error": "llama runner process has terminated: %!w(<nil>)" }
        // → on expose "llama runner process has terminated" plutôt que le JSON brut.
        const rawBody = await res.text().catch(() => res.statusText);

        let internalError: string = rawBody;
        try {
          const parsed = JSON.parse(rawBody) as OllamaErrorBody;
          if (parsed.error && typeof parsed.error === 'string') {
            // Extraire uniquement la partie significative (avant le ": %!w...")
            internalError = parsed.error.split(':')[0].trim();
          }
        } catch {
          // rawBody n'est pas du JSON valide — on le garde tel quel
        }

        if (res.status === 404) {
          throw new Error(
            `Modèle "${this.ollamaModel}" introuvable. ` +
            `Lancez : docker exec khidmeti-ollama ollama pull ${this.ollamaModel}`,
          );
        }

        throw new Error(`Ollama ${res.status}: ${internalError}`);
      }

      const data = await res.json() as OllamaResponse;

      // FIX v7 : Vérification explicite du content.
      // Ollama peut retourner content=null quand le runner est instable.
      // Retourner 'null' (string) causerait JSON.parse errors dans parse().
      const content = data.choices?.[0]?.message?.content;
      if (!content || typeof content !== 'string') {
        throw new Error(`Ollama returned empty or null content — runner may be unstable`);
      }

      return content;

    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        throw new Error(
          `Ollama timeout (${this.ollamaTimeout}ms) — CPU lent ou modèle non chargé. ` +
          `Vérifiez : make logs-ollama`,
        );
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
