// apps/api/src/modules/ai/ai.module.ts
//
// Strategy Pattern factory — sélection du backend IA au démarrage.
//
// AI_PROVIDER=openrouter → OpenRouterStrategy (texte/image GRATUIT + audio Gemini)
// AI_PROVIDER=gemini     → GeminiStrategy     (tout via Google AI Studio)
// AI_PROVIDER=ollama     → OllamaStrategy     (local Gemma4 via Ollama)
// AI_PROVIDER=vllm       → OllamaStrategy     (GPU serveur, même interface)
//
// RECOMMANDÉ EN PRODUCTION : AI_PROVIDER=openrouter
//   → Gemma 4 31B gratuit pour extraction d'intent (texte + image)
//   → Gemini pour l'audio uniquement (coût minimal, qualité Darija excellente)

import { Module, Logger } from '@nestjs/common';
import { AI_PROVIDER_TOKEN }      from './interfaces/ai-provider.interface';
import { GeminiStrategy }         from './providers/gemini.strategy';
import { OllamaStrategy }         from './providers/ollama.strategy';
import { OpenRouterStrategy }     from './providers/openrouter.strategy';
import { IntentExtractorService } from './services/intent-extractor.service';
import { AiController }           from './ai.controller';
import { AuthModule }             from '../auth/auth.module';
import Redis                      from 'ioredis';

const logger = new Logger('AiModule');

@Module({
  imports:     [AuthModule],
  controllers: [AiController],
  providers: [
    // ── Sélection de la stratégie ────────────────────────────────────────────
    {
      provide:    AI_PROVIDER_TOKEN,
      useFactory: () => {
        const provider = process.env['AI_PROVIDER'] ?? 'openrouter';

        switch (provider) {
          // ──────────────────────────────────────────────────────────────────
          // openrouter : Gemma 4 31B GRATUIT (texte + image) + Gemini (audio)
          // RECOMMANDÉ — coût ~0 pour 95% des appels
          // ──────────────────────────────────────────────────────────────────
          case 'openrouter': {
            const model = process.env['OPENROUTER_MODEL'] ?? 'google/gemma-4-31b-it:free';
            logger.log(`🤖 AI backend: OpenRouter (${model}) + Gemini audio`);
            return new OpenRouterStrategy();
          }

          // ──────────────────────────────────────────────────────────────────
          // gemini : Tout via Google AI Studio (texte + image + audio)
          // Utile pour debug ou si OpenRouter est indisponible
          // ──────────────────────────────────────────────────────────────────
          case 'gemini': {
            const model = process.env['GEMMA4_MODEL'] ?? 'gemma-4-31b-it';
            logger.log(`🤖 AI backend: Google AI Studio (${model})`);
            return new GeminiStrategy();
          }

          // ──────────────────────────────────────────────────────────────────
          // ollama / vllm : Gemma4 local (zéro coût, zéro GPU requis pour e2b/e4b)
          // ──────────────────────────────────────────────────────────────────
          case 'ollama':
          case 'vllm': {
            const model = process.env['OLLAMA_MODEL'] ?? 'gemma4:e4b';
            logger.log(`🤖 AI backend: Ollama/local (${model})`);
            return new OllamaStrategy();
          }

          default:
            throw new Error(
              `Unknown AI_PROVIDER="${provider}". ` +
              `Valid values: openrouter | gemini | ollama | vllm`,
            );
        }
      },
    },

    // ── Redis (optionnel — dégradation gracieuse sans lui) ───────────────────
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

    // ── Services ─────────────────────────────────────────────────────────────
    IntentExtractorService,
  ],
  exports: [IntentExtractorService, AI_PROVIDER_TOKEN],
})
export class AiModule {}
