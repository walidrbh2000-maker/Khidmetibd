import { Injectable } from '@nestjs/common';

export type AiProviderType = 'gemini' | 'ollama' | 'vllm';

@Injectable()
export class AiConfigService {
  get provider(): AiProviderType {
    const p = process.env['AI_PROVIDER'] ?? 'gemini';
    if (p !== 'gemini' && p !== 'ollama' && p !== 'vllm') {
      throw new Error(`Invalid AI_PROVIDER: ${p}. Must be gemini | ollama | vllm`);
    }
    return p;
  }

  get geminiApiKey(): string {
    return process.env['GEMINI_API_KEY'] ?? '';
  }

  get ollamaBaseUrl(): string {
    return process.env['OLLAMA_BASE_URL'] ?? 'http://ollama:11434';
  }

  get ollamaModel(): string {
    return process.env['OLLAMA_MODEL'] ?? 'gemma4:e2b';
  }

  get ollamaTimeoutMs(): number {
    return parseInt(process.env['OLLAMA_TIMEOUT_MS'] ?? '15000', 10);
  }

  get whisperBaseUrl(): string {
    return process.env['WHISPER_BASE_URL'] ?? 'http://whisper:9000';
  }

  get vllmBaseUrl(): string {
    return process.env['VLLM_BASE_URL'] ?? 'http://vllm:8000';
  }

  get qdrantUrl(): string {
    return process.env['QDRANT_URL'] ?? 'http://qdrant:6333';
  }

  get qdrantApiKey(): string {
    return process.env['QDRANT_API_KEY'] ?? '';
  }
}
