import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { MongooseModule } from '@nestjs/mongoose';
import { ThrottlerModule } from '@nestjs/throttler';
import { DatabaseModule } from './database/database.module';
import { QdrantModule } from './qdrant/qdrant.module';
import { FirebaseConfigModule } from './config/firebase.config';
import { AiModule } from './modules/ai/ai.module';
import { MediaModule } from './modules/media/media.module';
import { UsersModule } from './modules/users/users.module';
import { WorkersModule } from './modules/workers/workers.module';
import { ServiceRequestsModule } from './modules/service-requests/service-requests.module';
import { BidsModule } from './modules/bids/bids.module';
import { LocationModule } from './modules/location/location.module';
import { NotificationsModule } from './modules/notifications/notifications.module';
import { HealthController } from './health.controller';

@Module({
  imports: [
    // ── Config (env vars) ──────────────────────────────────────────────────
    ConfigModule.forRoot({
      isGlobal:    true,
      envFilePath: '../../.env',
    }),

    // ── Firebase Admin (verifies ID tokens in FirebaseAuthGuard) ───────────
    FirebaseConfigModule,

    // ── MongoDB ────────────────────────────────────────────────────────────
    MongooseModule.forRootAsync({
      imports:    [ConfigModule],
      inject:     [ConfigService],
      useFactory: (config: ConfigService) => ({
        uri:                      config.getOrThrow<string>('MONGODB_URI'),
        maxPoolSize:              10,
        serverSelectionTimeoutMS: 5000,
        socketTimeoutMS:          45000,
      }),
    }),

    // ── Rate limiting ──────────────────────────────────────────────────────
    ThrottlerModule.forRoot([
      { name: 'short',  ttl: 1_000,  limit: 20  },
      { name: 'medium', ttl: 10_000, limit: 100 },
      { name: 'long',   ttl: 60_000, limit: 300 },
    ]),

    // ── Domain modules ─────────────────────────────────────────────────────
    DatabaseModule,
    QdrantModule,
    AiModule,
    MediaModule,
    UsersModule,
    WorkersModule,
    ServiceRequestsModule,
    BidsModule,
    LocationModule,
    NotificationsModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
