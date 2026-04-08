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
  UseGuards,
} from '@nestjs/common';
import { FirebaseAuthGuard } from '../../common/guards/firebase-auth.guard';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { AuthUser } from '../../common/guards/firebase-auth.guard';
import { UsersService } from './users.service';
import { CreateUserDto } from '../../dto/create-user.dto';
import { UpdateUserDto } from '../../dto/update-user.dto';
import { UpdateLocationDto } from '../../dto/update-location.dto';
import { UpdateFcmTokenDto } from '../../dto/update-fcm-token.dto';
import { UserDocument } from '../../schemas/user.schema';

@Controller('users')
@UseGuards(FirebaseAuthGuard)
export class UsersController {
  constructor(private readonly usersService: UsersService) {}

  /**
   * POST /users
   * Create or update the caller's user profile.
   */
  @Post()
  @HttpCode(HttpStatus.OK)
  async upsert(
    @Body() dto: CreateUserDto,
    @CurrentUser() user: AuthUser,
  ): Promise<UserDocument> {
    if (dto.id !== user.uid) {
      throw new ForbiddenException('You can only create your own profile');
    }
    return this.usersService.upsert(dto);
  }

  /**
   * GET /users/:id
   * Fetch a user profile. Any authenticated user can read any profile.
   */
  @Get(':id')
  async findById(@Param('id') id: string): Promise<UserDocument> {
    return this.usersService.findById(id);
  }

  /**
   * PATCH /users/:id
   * Update the caller's own profile fields.
   */
  @Patch(':id')
  async update(
    @Param('id') id: string,
    @Body() dto: UpdateUserDto,
    @CurrentUser() user: AuthUser,
  ): Promise<UserDocument> {
    if (id !== user.uid) {
      throw new ForbiddenException('You can only update your own profile');
    }
    return this.usersService.update(id, dto);
  }

  /**
   * PATCH /users/:id/location
   * Update GPS coordinates for a user.
   */
  @Patch(':id/location')
  @HttpCode(HttpStatus.NO_CONTENT)
  async updateLocation(
    @Param('id') id: string,
    @Body() dto: UpdateLocationDto,
    @CurrentUser() user: AuthUser,
  ): Promise<void> {
    if (id !== user.uid) {
      throw new ForbiddenException('You can only update your own location');
    }
    return this.usersService.updateLocation(
      id,
      dto.latitude,
      dto.longitude,
      dto.cellId,
      dto.wilayaCode,
      dto.geoHash,
    );
  }

  /**
   * PATCH /users/:id/fcm-token
   * Update the FCM push notification token.
   */
  @Patch(':id/fcm-token')
  @HttpCode(HttpStatus.NO_CONTENT)
  async updateFcmToken(
    @Param('id') id: string,
    @Body() dto: UpdateFcmTokenDto,
    @CurrentUser() user: AuthUser,
  ): Promise<void> {
    if (id !== user.uid) {
      throw new ForbiddenException('You can only update your own FCM token');
    }
    return this.usersService.updateFcmToken(id, dto.fcmToken);
  }
}
