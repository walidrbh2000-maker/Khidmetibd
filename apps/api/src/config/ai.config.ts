// apps/api/src/config/ai.config.ts

import { Injectable } from '@nestjs/common';

export type AiProviderType = 'openrouter' | 'gemini' | 'ollama' | 'vllm';

@Injectable()
export class AiConfigService {
  get provider(): AiProviderType {
    const p = process.env['AI_PROVIDER'] ?? 'openrouter';
    if (p !== 'openrouter' && p !== 'gemini' && p !== 'ollama' && p !== 'vllm') {
      throw new Error(`Invalid AI_PROVIDER: ${p}. Must be openrouter | gemini | ollama | vllm`);
    }
    return p;
  }

  // ── OpenRouter ───────────────────────────────────────────────────────────

  get openRouterApiKey(): string {
    return process.env['OPENROUTER_API_KEY'] ?? '';
  }

  /** Modèle OpenRouter. Par défaut : Gemma 4 31B gratuit. */
  get openRouterModel(): string {
    return process.env['OPENROUTER_MODEL'] ?? 'google/gemma-4-31b-it:free';
  }

  get openRouterTimeoutMs(): number {
    return parseInt(process.env['OPENROUTER_TIMEOUT_MS'] ?? '35000', 10);
  }

  // ── Google AI Studio ─────────────────────────────────────────────────────

  get geminiApiKey(): string {
    return process.env['GEMINI_API_KEY'] ?? '';
  }

  /** Modèle Gemini pour l'audio (transcription multilingue Darija/Arabe). */
  get geminiAudioModel(): string {
    return process.env['GEMINI_AUDIO_MODEL'] ?? 'gemini-2.5-flash-lite';
  }

  // ── Ollama / vLLM ────────────────────────────────────────────────────────

  get ollamaBaseUrl(): string {
    return process.env['OLLAMA_BASE_URL'] ?? 'http://ollama:11434';
  }

  get ollamaModel(): string {
    return process.env['OLLAMA_MODEL'] ?? 'gemma4:e2b';
  }

  get ollamaTimeoutMs(): number {
    return parseInt(process.env['OLLAMA_TIMEOUT_MS'] ?? '15000', 10);
  }

  get vllmBaseUrl(): string {
    return process.env['VLLM_BASE_URL'] ?? 'http://vllm:8000';
  }

  // ── Services partagés ────────────────────────────────────────────────────

  get whisperBaseUrl(): string {
    return process.env['WHISPER_BASE_URL'] ?? 'http://whisper:9000';
  }

  get qdrantUrl(): string {
    return process.env['QDRANT_URL'] ?? 'http://qdrant:6333';
  }

  get qdrantApiKey(): string {
    return process.env['QDRANT_API_KEY'] ?? '';
  }
}
