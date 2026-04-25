// apps/api/src/modules/ai/providers/gemma4.strategy.ts
//
// v14.3 — Deux correctifs critiques :
//
// FIX 1 : AUDIO_INTENT_SYSTEM_PROMPT réduit (~100 tokens vs ~1500 avant)
//   Même logique que SYSTEM_PROMPT dans intent-extractor.service.ts v14.3.
//   Prefill audio estimé : ~100 tok / 8 tok/s = 12s. Génération : ~12s. Total ~24s.
//
// FIX 2 : TRANSCODING AUDIO via ffmpeg (résout erreur 400)
//   llama.cpp ne supporte que 'wav' et 'mp3'.
//   iOS envoie m4a (audio/m4a), Android peut envoyer ogg/webm.
//   Solution : transcodeToWav() convertit tout format → WAV 16kHz mono PCM
//   avant envoi à llama.cpp. ffmpeg doit être installé dans le container API
//   (apk add ffmpeg dans le Dockerfile — voir Dockerfile v14.3).
//
// FIX 3 : maxTokens 512 → 128 par défaut
//   JSON output ~50 tokens max. Réduit le temps de génération de 50%.
//
// PRÉREQUIS : ffmpeg installé dans le container API
//   → Dockerfile v14.3 : apk add --no-cache ffmpeg (dans base stage)
//
// FORMAT AUDIO RECOMMANDÉ (après fix) :
//   N'importe quel format supporté par ffmpeg (wav, mp3, m4a, ogg, webm, flac, aac)
//   Transcoding automatique vers WAV 16kHz mono PCM (optimal llama.cpp PR#21421)

import { Injectable, Logger }     from '@nestjs/common';
import { execFile }                from 'child_process';
import { promisify }               from 'util';
import { writeFile, readFile, unlink } from 'fs/promises';
import { join }                    from 'path';
import { tmpdir }                  from 'os';
import { randomUUID }              from 'crypto';
import type { IAiProvider, AudioResult } from '../interfaces/ai-provider.interface';

// ── Promisify execFile (Node.js built-in, aucun package npm requis) ───────────
const execFileAsync = promisify(execFile);

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
// WAV 16kHz mono 16-bit = 32 000 bytes/s → 30s = ~960 KB
// Marge à 5 MB (couvre la plupart des formats compressés)
const MAX_AUDIO_BYTES = 5 * 1024 * 1024; // 5 MB

// Timeout audio par défaut
const AUDIO_TIMEOUT_FALLBACK_MS = 180_000; // 3 minutes (match GEMMA4_TIMEOUT_MS .env v14.3)

// ── AUDIO_INTENT_SYSTEM_PROMPT — v14.3 : MINIMAL (~100 tokens) ────────────────
//
// AVANT v14.3 : ~1500 tokens → prefill 180-375 secondes sur CPU → TIMEOUT
// APRÈS v14.3 : ~100 tokens → prefill ~12 secondes → FONCTIONNE
//
// Gemma4 comprend le Darija algérien nativement.
// Le format JSON et les 3 règles essentielles suffisent.

const AUDIO_INTENT_SYSTEM_PROMPT = `\
You are a home-service intent extractor for Khidmeti (Algeria).
Listen to the voice message in Algerian Darija, French, Arabic, or any mix.

Reply ONLY with valid JSON on one line — no transcription, no explanation, nothing else:
{"profession":<string|null>,"is_urgent":<bool>,"problem_description":<string>,"max_radius_km":<number|null>,"confidence":<number>}

profession (exact value or null): plumber|electrician|cleaner|painter|carpenter|gardener|ac_repair|appliance_repair|mason|mechanic|mover
is_urgent=true ONLY: active flooding / total power outage / gas leak / locked door at night
problem_description: factual English, max 100 chars
confidence: 0.0–1.0 (0.0 if profession unknown, never null)
`;

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Supprime les balises de "thinking" que Gemma4 peut émettre
 * et nettoie les backticks markdown résiduels.
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
    this.gemma4Timeout = parseInt(
      process.env['GEMMA4_TIMEOUT_MS'] ?? String(AUDIO_TIMEOUT_FALLBACK_MS),
      10,
    );

    this.logger.log(
      `✅ Gemma4Strategy v14.3 — single-model multimodal (texte + image + audio natif)\n` +
      `   └─ endpoint    : ${this.gemma4Url}\n` +
      `   └─ timeout     : ${this.gemma4Timeout}ms\n` +
      `   └─ audio max   : ${MAX_AUDIO_BYTES / 1024 / 1024} MB (~30s WAV 16kHz)\n` +
      `   └─ transcoding : ffmpeg → WAV 16kHz mono (fix erreur 400 m4a/ogg/etc.)\n` +
      `   └─ prompt      : ~100 tokens (fix timeout CPU)`,
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
      // v14.3 : maxTokens 512 → 128 par défaut (JSON ~50 tokens max)
      { temperature: opts.temperature ?? 0.05, maxTokens: opts.maxTokens ?? 128 },
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
              text: 'Analyze this image and extract the home service intent as the exact JSON format requested.',
            },
          ],
        },
      ],
      // v14.3 : maxTokens 512 → 128 par défaut
      { temperature: opts.temperature ?? 0.05, maxTokens: opts.maxTokens ?? 128 },
    );
  }

  // ── IAiProvider : processAudio ─────────────────────────────────────────────
  //
  // v14.3 — Transcoding automatique vers WAV 16kHz mono (fix erreur 400)
  //
  // PROBLÈME v14.0-14.2 :
  //   llama.cpp PR#21421 n'accepte que 'wav' et 'mp3'.
  //   iOS envoie m4a (audio/m4a → normalisé audio/mp4 → ext m4a).
  //   Résultat : erreur 400 "input_audio.format must be either 'wav' or 'mp3'"
  //
  // FIX v14.3 :
  //   transcodeToWav() convertit TOUT format → WAV 16kHz mono PCM via ffmpeg.
  //   ffmpeg auto-détecte le format d'entrée (pas besoin de spécifier).
  //   Après transcoding, on envoie toujours format='wav' à llama.cpp.
  //
  // PIPELINE v14.3 :
  //   Buffer(n'importe quel format) → ffmpeg → Buffer(WAV 16kHz mono) → Gemma4

  async processAudio(
    buffer: Buffer,
    mime:   string,
    _opts:  { temperature?: number; maxTokens?: number } = {},
  ): Promise<AudioResult> {
    // ── Validation taille (avant transcoding) ────────────────────────────────
    if (buffer.length > MAX_AUDIO_BYTES) {
      throw new Error(
        `Audio trop long : ${(buffer.length / 1024 / 1024).toFixed(1)} MB ` +
        `(max ${MAX_AUDIO_BYTES / 1024 / 1024} MB ≈ 30s WAV 16kHz mono). ` +
        `Raccourcissez l'enregistrement ou réduisez la qualité.`,
      );
    }

    const normalizedMime = this.normalizeMime(mime);

    this.logger.debug(
      `Audio natif Gemma4 v14.3 — ` +
      `mime_original=${mime} mime_normalisé=${normalizedMime} ` +
      `taille=${(buffer.length / 1024).toFixed(0)} KB → transcoding WAV 16kHz`,
    );

    // ── Transcoding vers WAV 16kHz mono (fix erreur 400) ─────────────────────
    let audioBuffer: Buffer;
    try {
      audioBuffer = await this.transcodeToWav(buffer, normalizedMime);
    } catch (err) {
      const msg = (err as Error).message;
      this.logger.error(`Transcoding audio échoué : ${msg}`);
      throw new Error(`Audio transcoding failed: ${msg}`);
    }

    // ── Validation taille après transcoding (WAV non compressé = plus gros) ──
    if (audioBuffer.length > MAX_AUDIO_BYTES) {
      throw new Error(
        `Audio WAV trop grand après transcoding : ${(audioBuffer.length / 1024 / 1024).toFixed(1)} MB. ` +
        `Audio source trop long — max ~30s.`,
      );
    }

    const audioBase64 = audioBuffer.toString('base64');

    // ── Envoi à Gemma4 (format API mtmd OpenAI-compatible) ───────────────────
    // Toujours 'wav' après transcoding — llama.cpp l'accepte sans erreur
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
              input_audio: { data: audioBase64, format: 'wav' }, // toujours wav après transcoding
            },
            {
              type: 'text',
              text: 'Listen to this voice message and extract the home service intent as the exact JSON format requested.',
            },
          ],
        },
      ],
      {
        temperature: _opts.temperature ?? 0.05,
        maxTokens:   _opts.maxTokens   ?? 128, // v14.3 : 512 → 128
      },
    );

    return { text: raw, language: 'auto' };
  }

  // ── Privé : transcodeToWav ─────────────────────────────────────────────────
  //
  // Convertit n'importe quel format audio en WAV 16kHz mono PCM via ffmpeg.
  //
  // POURQUOI ffmpeg :
  //   - llama.cpp PR#21421 n'accepte que 'wav' et 'mp3'
  //   - iOS envoie m4a, Android peut envoyer ogg/webm/aac
  //   - ffmpeg est universel et performant (transcoding < 500ms pour <60s audio)
  //
  // PARAMÈTRES ffmpeg :
  //   -ar 16000  : 16kHz sample rate (optimal pour la reconnaissance vocale)
  //   -ac 1      : mono (réduit la taille, Gemma4 speech ne nécessite pas stéréo)
  //   -c:a pcm_s16le : PCM 16-bit signed little-endian (WAV standard)
  //   -f wav     : force le container WAV
  //
  // GESTION DES ERREURS :
  //   ENOENT  → ffmpeg non installé → erreur claire avec instruction d'installation
  //   Autres  → erreur de format ou corruption → propagée avec message clair
  //
  // FICHIERS TEMPORAIRES :
  //   /tmp/khidmeti_<uuid>_in.<ext>  → buffer d'entrée
  //   /tmp/khidmeti_<uuid>_out.wav   → résultat WAV
  //   Nettoyés dans finally (même en cas d'erreur)

  private async transcodeToWav(buffer: Buffer, normalizedMime: string): Promise<Buffer> {
    // Si déjà WAV, pas besoin de transcoder
    if (normalizedMime === 'audio/wav') {
      this.logger.debug('Audio déjà en WAV — transcoding ignoré');
      return buffer;
    }

    const uid       = randomUUID().slice(0, 8);
    const inputExt  = this.mimeToExt(normalizedMime);
    const inputPath = join(tmpdir(), `khidmeti_${uid}_in.${inputExt}`);
    const outputPath = join(tmpdir(), `khidmeti_${uid}_out.wav`);

    const startMs = Date.now();

    try {
      // Écriture du buffer d'entrée
      await writeFile(inputPath, buffer);

      // Transcoding via ffmpeg
      await execFileAsync('ffmpeg', [
        '-y',                  // overwrite sans demander
        '-i', inputPath,       // entrée auto-détectée par ffmpeg
        '-ar', '16000',        // 16kHz sample rate
        '-ac', '1',            // mono
        '-c:a', 'pcm_s16le',  // 16-bit PCM little-endian
        '-f', 'wav',           // container WAV
        outputPath,
      ], {
        timeout: 30_000,       // 30s max pour le transcoding
      });

      const wavBuffer = await readFile(outputPath);
      const durationMs = Date.now() - startMs;

      this.logger.log(
        `✅ Audio transcodé : ${(buffer.length / 1024).toFixed(0)} KB ${normalizedMime} ` +
        `→ ${(wavBuffer.length / 1024).toFixed(0)} KB WAV 16kHz mono ` +
        `(${durationMs}ms)`,
      );

      return wavBuffer;

    } catch (err) {
      const e = err as NodeJS.ErrnoException & { stderr?: string; stdout?: string };

      // ffmpeg non installé
      if (e.code === 'ENOENT' || e.message?.includes('ENOENT')) {
        throw new Error(
          `ffmpeg non disponible dans le container API. ` +
          `Ajoutez "apk add --no-cache ffmpeg" dans apps/api/Dockerfile (base stage). ` +
          `Format audio reçu : ${normalizedMime}. ` +
          `llama.cpp accepte uniquement wav et mp3.`,
        );
      }

      // Timeout ffmpeg
      if (e.message?.includes('timeout') || e.code === 'ETIMEDOUT') {
        throw new Error(
          `Transcoding audio timeout (>30s) pour ${normalizedMime}. ` +
          `Fichier trop long ou corrompu.`,
        );
      }

      // Autres erreurs ffmpeg (format corrompu, codec inconnu, etc.)
      const ffmpegErr = e.stderr ?? e.message ?? String(err);
      throw new Error(`ffmpeg transcoding échoué (${normalizedMime}): ${ffmpegErr.slice(0, 200)}`);

    } finally {
      // Nettoyage fichiers temporaires (toujours, même en cas d'erreur)
      await unlink(inputPath).catch(() => { /* ignore si déjà supprimé */ });
      await unlink(outputPath).catch(() => { /* ignore si jamais créé */ });
    }
  }

  // ── Privé : chat générique ────────────────────────────────────────────────

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
          max_tokens:  opts.maxTokens   ?? 128, // v14.3 : 512 → 128
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

        if (res.status === 400 || res.status === 422) {
          throw new Error(
            `Gemma4 requête rejetée (${res.status}): ${errMsg}. ` +
            `Pour l'audio : vérifiez (1) format WAV après transcoding, ` +
            `(2) mmproj BF16 présent dans docker/models/gemma4/, ` +
            `(3) image llama.cpp récente avec PR#21421.`,
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
          `Vérifiez GEMMA4_TIMEOUT_MS dans .env (valeur recommandée : 180000). ` +
          `Le SYSTEM_PROMPT v14.3 est court (~150 tokens) — si timeout persist, ` +
          `le serveur llama.cpp est peut-être surchargé.`,
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
   * iOS envoie audio/x-m4a ou audio/m4a → normalisé en audio/mp4.
   * Android peut envoyer audio/ogg, audio/webm, etc.
   * application/octet-stream → audio/wav (format le plus courant en dev).
   */
  private normalizeMime(mime: string): string {
    if (!mime || mime === 'application/octet-stream') return 'audio/wav';
    const map: Record<string, string> = {
      // WAV — toutes variantes
      'audio/x-wav':       'audio/wav',
      'audio/wave':        'audio/wav',
      'audio/vnd.wave':    'audio/wav',
      // M4A / MP4 (iOS default recorder)
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
   * Convertit un MIME type audio en extension de fichier.
   * Utilisé pour nommer le fichier temporaire d'entrée pour ffmpeg.
   * ffmpeg auto-détecte le format — l'extension aide mais n'est pas critique.
   */
  private mimeToExt(mime: string): string {
    const map: Record<string, string> = {
      'audio/wav':  'wav',
      'audio/mp3':  'mp3',
      'audio/mp4':  'm4a',   // m4a = AAC dans container MP4
      'audio/ogg':  'ogg',
      'audio/flac': 'flac',
      'audio/webm': 'webm',
      'audio/aac':  'aac',
    };
    return map[mime] ?? 'bin'; // extension générique si inconnu
  }
}
