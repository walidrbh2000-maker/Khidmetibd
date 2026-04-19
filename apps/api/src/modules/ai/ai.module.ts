// apps/api/src/modules/ai/ai.module.ts
//
// Architecture simplifiée — un seul backend IA 100% local.
// Pas de factory, pas de switch, pas de stratégies multiples.
//
// Ollama  → gemma4:e2b → texte + image (multimodal natif)
// Whisper → faster-whisper small → audio (Darija / Arabe / Français)

import { Module }  from '@nestjs/common';
import { AI_PROVIDER_TOKEN } from './interfaces/ai-provider.interface';
import { LocalStrategy }     from './providers/local.strategy';
import { IntentExtractorService } from './services/intent-extractor.service';
import { AiController }      from './ai.controller';
import { AuthModule }        from '../auth/auth.module';
import Redis                 from 'ioredis';

@Module({
  imports:     [AuthModule],
  controllers: [AiController],
  providers: [
    // ── Backend IA unique (100% local) ────────────────────────────────────────
    LocalStrategy,
    {
      provide:     AI_PROVIDER_TOKEN,
      useExisting: LocalStrategy,
    },

    // ── Redis — rate-limiting optionnel (dégradation gracieuse si absent) ─────
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
        client.on('error', () => { /* silent */ });
        return client;
      },
    },

    IntentExtractorService,
  ],
  exports: [IntentExtractorService, AI_PROVIDER_TOKEN],
})
export class AiModule {}
