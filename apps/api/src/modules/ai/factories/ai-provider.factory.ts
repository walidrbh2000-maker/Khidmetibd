import { AiProvider } from '../interfaces/ai-provider.interface';
import { GeminiProvider } from '../providers/gemini.provider';
import { OllamaProvider } from '../providers/ollama.provider';
import { VllmProvider } from '../providers/vllm.provider';

export type AiProviderType = 'gemini' | 'ollama' | 'vllm';

/**
 * Factory function injected as a NestJS provider via useFactory.
 * Reads AI_PROVIDER env var at startup and returns the correct implementation.
 * AI_PROVIDER=gemini (default) — works on any machine, no GPU needed.
 * AI_PROVIDER=ollama            — local inference, 16 GB+ RAM.
 * AI_PROVIDER=vllm              — NVIDIA GPU required, 16 GB+ VRAM.
 */
export function createAiProvider(): AiProvider {
  const raw = process.env['AI_PROVIDER'] ?? 'gemini';
  switch (raw) {
    case 'ollama':
      return new OllamaProvider();
    case 'vllm':
      return new VllmProvider();
    case 'gemini':
      return new GeminiProvider();
    default:
      throw new Error(
        `Unknown AI_PROVIDER: "${raw}". Allowed values: gemini | ollama | vllm`,
      );
  }
}
