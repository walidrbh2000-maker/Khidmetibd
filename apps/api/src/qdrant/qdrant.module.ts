import { Module, Global } from '@nestjs/common';
import { QdrantInitService } from './qdrant-init.service';

@Global()
@Module({
  providers: [QdrantInitService],
  exports: [QdrantInitService],
})
export class QdrantModule {}
