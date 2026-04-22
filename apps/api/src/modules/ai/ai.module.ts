// apps/api/src/modules/ai/ai.module.ts
//
// v14 — Gemma4Strategy : modèle unique texte + image + audio natif
//
// MIGRATION v14 :
//   SUPPRIMÉ : ai-audio (Whisper faster-whisper-server)
//   Gemma4 gère désormais texte + images + audio en un seul service
//
// Architecture simplifiée :
//   Avant v14 : Gemma4 (texte + image) + Whisper (audio STT)
//   Après v14 : Gemma4 uniquement (texte + image + audio natif)
//
// L'interface IAiProvider est conservée pour l'extensibilité future
// (ex: basculer vers Gemma4 E4B GPU sans changer IntentExtractorService).

import { Module }  from '@nestjs/common';
import { AI_PROVIDER_TOKEN } from './interfaces/ai-provider.interface';
import { Gemma4Strategy }   from './providers/gemma4.strategy';
import { IntentExtractorService } from './services/intent-extractor.service';
import { AiController } from './ai.controller';
import { AuthModule }   from '../auth/auth.module';
import Redis            from 'ioredis';

@Module({
  imports:     [AuthModule],
  controllers: [AiController],
  providers: [
    // ── Backend IA Gemma4 (texte + image + audio natif) ──────────────────────
    Gemma4Strategy,
    {
      provide:     AI_PROVIDER_TOKEN,
      useExisting: Gemma4Strategy,
    },

    // ── Redis — rate-limiting (dégradation gracieuse si absent) ───────────────
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
        client.on('error', () => { /* silent — Redis est optionnel */ });
        return client;
      },
    },

    IntentExtractorService,
  ],
  exports: [IntentExtractorService, AI_PROVIDER_TOKEN],
})
export class AiModule {}
