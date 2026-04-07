import {
  Controller,
  Post,
  Delete,
  Param,
  UseGuards,
  UseInterceptors,
  UploadedFile,
  BadRequestException,
  HttpCode,
  HttpStatus,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { FirebaseAuthGuard } from '../../common/guards/firebase-auth.guard';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { AuthUser } from '../../common/guards/firebase-auth.guard';
import { MediaService, UploadResult } from './media.service';

@Controller('media')
@UseGuards(FirebaseAuthGuard)
export class MediaController {
  constructor(private readonly mediaService: MediaService) {}

  @Post('upload/image')
  @HttpCode(HttpStatus.OK)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 10 * 1024 * 1024 } }))
  async uploadImage(
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthUser,
  ): Promise<UploadResult> {
    if (!file?.buffer?.length) throw new BadRequestException('file is required');
    return this.mediaService.uploadImage(file.buffer, file.mimetype, user.uid);
  }

  @Post('upload/video')
  @HttpCode(HttpStatus.OK)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 100 * 1024 * 1024 } }))
  async uploadVideo(
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthUser,
  ): Promise<UploadResult> {
    if (!file?.buffer?.length) throw new BadRequestException('file is required');
    return this.mediaService.uploadVideo(file.buffer, file.mimetype, user.uid);
  }

  @Post('upload/audio')
  @HttpCode(HttpStatus.OK)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 50 * 1024 * 1024 } }))
  async uploadAudio(
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthUser,
  ): Promise<UploadResult> {
    if (!file?.buffer?.length) throw new BadRequestException('file is required');
    return this.mediaService.uploadAudio(file.buffer, file.mimetype, user.uid);
  }

  @Delete(':bucket/:key')
  @HttpCode(HttpStatus.NO_CONTENT)
  async deleteFile(
    @Param('bucket') bucket: string,
    @Param('key') key: string,
    @CurrentUser() user: AuthUser,
  ): Promise<void> {
    return this.mediaService.deleteFile(bucket, decodeURIComponent(key), user.uid);
  }
}
