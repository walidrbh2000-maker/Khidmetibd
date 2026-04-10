// ══════════════════════════════════════════════════════════════════════════════
// AiController — unchanged public API surface
// Uses IntentExtractorService which now depends on IAiProvider (Strategy Pattern)
// ══════════════════════════════════════════════════════════════════════════════

import {
  Controller,
  Post,
  Body,
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
import type { AuthUser } from '../../common/guards/firebase-auth.guard';
import { IntentExtractorService } from './services/intent-extractor.service';
import type { SearchIntent } from './services/intent-extractor.service';
import { ExtractIntentDto } from './dto/extract-intent.dto';

@Controller('ai')
@UseGuards(FirebaseAuthGuard)
export class AiController {
  constructor(private readonly intentExtractor: IntentExtractorService) {}

  /** POST /ai/extract-intent — text (any language / Darija / Arabic / French) */
  @Post('extract-intent')
  @HttpCode(HttpStatus.OK)
  async extractIntent(
    @Body() dto: ExtractIntentDto,
    @CurrentUser() user: AuthUser,
  ): Promise<SearchIntent> {
    return this.intentExtractor.extractFromText(dto.text, user.uid);
  }

  /** POST /ai/extract-intent/audio — m4a / wav / mp3 / ogg */
  @Post('extract-intent/audio')
  @HttpCode(HttpStatus.OK)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 50 * 1024 * 1024 } }))
  async extractIntentFromAudio(
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthUser,
  ): Promise<SearchIntent> {
    if (!file?.buffer?.length) throw new BadRequestException('Audio file is required');
    return this.intentExtractor.extractFromAudio(file.buffer, file.mimetype, user.uid);
  }

  /** POST /ai/extract-intent/image — JPEG or PNG */
  @Post('extract-intent/image')
  @HttpCode(HttpStatus.OK)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 10 * 1024 * 1024 } }))
  async extractIntentFromImage(
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthUser,
  ): Promise<SearchIntent> {
    if (!file?.buffer?.length) throw new BadRequestException('Image file is required');

    const b = file.buffer;
    const isJpeg = b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
    const isPng  = b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
    if (!isJpeg && !isPng) throw new BadRequestException('Only JPEG and PNG images are supported');

    return this.intentExtractor.extractFromImage(b.toString('base64'), user.uid);
  }
}
