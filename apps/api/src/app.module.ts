// apps/api/src/app.module.ts
// FIX: HealthController now receives AI_PROVIDER_TOKEN via DI
// to expose circuit breaker health at GET /health/detail

import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { MongooseModule } from '@nestjs/mongoose';
import { ThrottlerModule } from '@nestjs/throttler';
import { DatabaseModule }           from './database/database.module';
import { QdrantModule }             from './qdrant/qdrant.module';
import { FirebaseConfigModule }     from './config/firebase.config';
import { AiModule }                 from './modules/ai/ai.module';
import { MediaModule }              from './modules/media/media.module';
import { UsersModule }              from './modules/users/users.module';
import { WorkersModule }            from './modules/workers/workers.module';
import { ServiceRequestsModule }    from './modules/service-requests/service-requests.module';
import { BidsModule }               from './modules/bids/bids.module';
import { LocationModule }           from './modules/location/location.module';
import { NotificationsModule }      from './modules/notifications/notifications.module';
import { GatewayModule }            from './modules/gateway/gateway.module';
import { HealthController }         from './health.controller';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, envFilePath: '../../.env' }),
    FirebaseConfigModule,

    MongooseModule.forRootAsync({
      imports:    [ConfigModule],
      inject:     [ConfigService],
      useFactory: (config: ConfigService) => ({
        uri:                      config.getOrThrow<string>('MONGODB_URI'),
        maxPoolSize:              10,
        serverSelectionTimeoutMS: 5000,
        socketTimeoutMS:          45000,
        // FIX: Suppress Mongoose 8.x autoIndex warnings on _id fields.
        // The 'users', 'worker_bids', etc. collections use string _id (Firebase UID).
        // Mongoose tries to add a sparse index on top of MongoDB's default _id index,
        // which logs "Warning: Can not overwrite the default `_id` index".
        // autoIndex: false in production means Mongoose won't attempt to sync indexes
        // on startup — run `db.collection.createIndexes()` in your migration instead.
        autoIndex: process.env['NODE_ENV'] !== 'production',
      }),
    }),

    ThrottlerModule.forRoot([
      { name: 'short',  ttl: 1_000,  limit: 20  },
      { name: 'medium', ttl: 10_000, limit: 100 },
      { name: 'long',   ttl: 60_000, limit: 300 },
    ]),

    DatabaseModule,
    QdrantModule,
    AiModule,       // exports AI_PROVIDER_TOKEN — HealthController can inject it
    MediaModule,
    UsersModule,
    WorkersModule,
    ServiceRequestsModule,
    BidsModule,
    LocationModule,
    NotificationsModule,
    GatewayModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
