import {
  Body,
  Controller,
  ForbiddenException,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { FirebaseAuthGuard }    from '../../common/guards/firebase-auth.guard';
import { CurrentUser }          from '../../common/decorators/current-user.decorator';
import { AuthUser }             from '../../common/guards/firebase-auth.guard';
import { WorkersService }       from './workers.service';
import { CreateWorkerDto }      from '../../dto/create-worker.dto';
import { UpdateWorkerDto }      from '../../dto/update-worker.dto';
import { UpdateLocationDto }    from '../../dto/update-location.dto';
import { UpdateFcmTokenDto }    from '../../dto/update-fcm-token.dto';
import { UpdateWorkerStatusDto } from '../../dto/update-worker-status.dto';
import { UserDocument }         from '../../schemas/user.schema';

@Controller('workers')
@UseGuards(FirebaseAuthGuard)
export class WorkersController {
  constructor(private readonly workersService: WorkersService) {}

  /** POST /workers — create or update caller's worker profile. */
  @Post()
  @HttpCode(HttpStatus.OK)
  async upsert(
    @Body() dto: CreateWorkerDto,
    @CurrentUser() user: AuthUser,
  ): Promise<UserDocument> {
    if (dto.id !== user.uid) throw new ForbiddenException('You can only create your own worker profile');
    return this.workersService.upsert(dto);
  }

  /** GET /workers — list workers (optionally filtered). */
  @Get()
  async findMany(
    @Query('wilayaCode') wilayaCodeStr?: string,
    @Query('profession') profession?: string,
    @Query('isOnline')   isOnlineStr?: string,
    @Query('cellId')     cellId?: string,
    @Query('limit')      limitStr?: string,
  ): Promise<UserDocument[]> {
    const wilayaCode = wilayaCodeStr ? parseInt(wilayaCodeStr, 10) : undefined;
    const isOnline   = isOnlineStr   !== undefined ? isOnlineStr === 'true' : undefined;
    const limit      = limitStr ? Math.min(parseInt(limitStr, 10), 200) : 100;

    return this.workersService.findMany({ wilayaCode, profession, isOnline, cellId, limit });
  }

  @Get(':id')
  async findById(@Param('id') id: string): Promise<UserDocument> {
    return this.workersService.findById(id);
  }

  @Patch(':id')
  async update(
    @Param('id') id: string,
    @Body() dto: UpdateWorkerDto,
    @CurrentUser() user: AuthUser,
  ): Promise<UserDocument> {
    if (id !== user.uid) throw new ForbiddenException('You can only update your own profile');
    return this.workersService.update(id, dto);
  }

  @Patch(':id/status')
  @HttpCode(HttpStatus.NO_CONTENT)
  async updateStatus(
    @Param('id') id: string,
    @Body() dto: UpdateWorkerStatusDto,
    @CurrentUser() user: AuthUser,
  ): Promise<void> {
    if (id !== user.uid) throw new ForbiddenException('You can only update your own status');
    return this.workersService.updateStatus(id, dto.isOnline);
  }

  @Patch(':id/location')
  @HttpCode(HttpStatus.NO_CONTENT)
  async updateLocation(
    @Param('id') id: string,
    @Body() dto: UpdateLocationDto,
    @CurrentUser() user: AuthUser,
  ): Promise<void> {
    if (id !== user.uid) throw new ForbiddenException('You can only update your own location');
    return this.workersService.updateLocation(
      id, dto.latitude, dto.longitude, dto.cellId, dto.wilayaCode, dto.geoHash,
    );
  }

  @Patch(':id/fcm-token')
  @HttpCode(HttpStatus.NO_CONTENT)
  async updateFcmToken(
    @Param('id') id: string,
    @Body() dto: UpdateFcmTokenDto,
    @CurrentUser() user: AuthUser,
  ): Promise<void> {
    if (id !== user.uid) throw new ForbiddenException('You can only update your own FCM token');
    return this.workersService.updateFcmToken(id, dto.fcmToken);
  }
}
