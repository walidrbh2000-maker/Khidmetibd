// ══════════════════════════════════════════════════════════════════════════════
// AiModule — Strategy Pattern factory
//
// AI_PROVIDER env var selects the backend at startup:
//   gemini  → GeminiStrategy  (Google AI API, current default)
//   ollama  → OllamaStrategy  (Local Gemma4 via Ollama, zero cost)
//   vllm    → OllamaStrategy  (same OpenAI-compat API, GPU server)
//
// Adding a new provider = create a new class implementing IAiProvider,
// add one case below.  Zero changes elsewhere.
// ══════════════════════════════════════════════════════════════════════════════

import { Module, Logger } from '@nestjs/common';
import { AI_PROVIDER_TOKEN }      from './interfaces/ai-provider.interface';
import { GeminiStrategy }         from './providers/gemini.strategy';
import { OllamaStrategy }         from './providers/ollama.strategy';
import { IntentExtractorService } from './services/intent-extractor.service';
import { AiController }           from './ai.controller';
import { AuthModule }             from '../auth/auth.module';
import Redis                      from 'ioredis';

const logger = new Logger('AiModule');

@Module({
  imports:     [AuthModule],
  controllers: [AiController],
  providers: [
    // ── Strategy selection ──────────────────────────────────────────────────
    {
      provide:    AI_PROVIDER_TOKEN,
      useFactory: () => {
        const provider = process.env['AI_PROVIDER'] ?? 'gemini';

        switch (provider) {
          case 'gemini':
            logger.log('🤖 AI backend: Gemini (Google AI API)');
            return new GeminiStrategy();

          case 'ollama':
          case 'vllm':
            logger.log(`🤖 AI backend: Ollama/local (${process.env['OLLAMA_MODEL'] ?? 'gemma4:e4b'})`);
            return new OllamaStrategy();

          default:
            throw new Error(
              `Unknown AI_PROVIDER="${provider}". Valid values: gemini | ollama | vllm`,
            );
        }
      },
    },

    // ── Redis (optional, graceful degradation without it) ───────────────────
    {
      provide:    'REDIS_CLIENT',
      useFactory: (): Redis | null => {
        const url = process.env['REDIS_URL'];
        if (!url) return null;

        const client = new Redis(url, {
          lazyConnect:          true,
          maxRetriesPerRequest: 1,
          enableOfflineQueue:   false,
        });
        client.on('error', () => { /* silent degradation */ });
        return client;
      },
    },

    // ── Services ────────────────────────────────────────────────────────────
    IntentExtractorService,
  ],
  exports: [IntentExtractorService, AI_PROVIDER_TOKEN],
})
export class AiModule {}
