import { Module } from '@nestjs/common';
import { AuthModule }       from '../auth/auth.module';
import { UsersModule }      from '../users/users.module';
import { WorkersService }   from './workers.service';
import { WorkersController } from './workers.controller';

@Module({
  imports: [AuthModule, UsersModule],   // ← UsersModule provides UsersService
  controllers: [WorkersController],
  providers:   [WorkersService],
  exports:     [WorkersService],
})
export class WorkersModule {}
