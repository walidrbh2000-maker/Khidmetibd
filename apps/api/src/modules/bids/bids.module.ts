import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { BidsService } from './bids.service';
import { BidsController } from './bids.controller';

@Module({
  imports: [AuthModule],
  controllers: [BidsController],
  providers: [BidsService],
  exports: [BidsService],
})
export class BidsModule {}
