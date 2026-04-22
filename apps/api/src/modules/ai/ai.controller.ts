// apps/api/src/modules/ai/ai.controller.ts
//
// v14.0 — Gemma4 Multimodal (Texte + Image + Audio Natif)
//
// Le controller reste simple : il reçoit les fichiers (images ou audio) et les
// passe au service.
// 
// NOUVEAUTÉ v14 : L'audio est désormais traité nativement par Gemma4 (plus de Whisper).
// Les formats d'images (JPEG, PNG, WebP) et audio (WAV, MP3, M4A) sont supportés.
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

  /**
   * POST /ai/extract-intent
   * Texte en Darija / Français / Arabe / mix → intention JSON
   */
  @Post('extract-intent')
  @HttpCode(HttpStatus.OK)
  async extractIntent(
    @Body() dto: ExtractIntentDto,
    @CurrentUser() user: AuthUser,
  ): Promise<SearchIntent> {
    return this.intentExtractor.extractFromText(dto.text, user.uid);
  }

  /**
   * POST /ai/extract-intent/audio
   * Audio (m4a / wav / mp3 / ogg) → Whisper STT → Gemma4 intent
   * Limite : 50 MB
   */
  @Post('extract-intent/audio')
  @HttpCode(HttpStatus.OK)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 50 * 1024 * 1024 } }))
  async extractIntentFromAudio(
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthUser,
  ): Promise<SearchIntent> {
    if (!file?.buffer?.length) {
      throw new BadRequestException('Fichier audio requis (m4a, wav, mp3, ogg)');
    }
    return this.intentExtractor.extractFromAudio(file.buffer, file.mimetype, user.uid);
  }

  /**
   * POST /ai/extract-intent/image
   * Image (JPEG, PNG, WebP) → Gemma4 analyse native → intent JSON
   *
   * Gemma4 E2B/E4B : analyse multimodale native en un seul step.
   * Limite : 10 MB
   *
   * Formats supportés (détection par magic bytes) :
   *   JPEG : FF D8 FF
   *   PNG  : 89 50 4E 47
   *   WebP : RIFF....WEBP (commun sur Android)
   */
  @Post('extract-intent/image')
  @HttpCode(HttpStatus.OK)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 10 * 1024 * 1024 } }))
  async extractIntentFromImage(
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthUser,
  ): Promise<SearchIntent> {
    if (!file?.buffer?.length) {
      throw new BadRequestException('Fichier image requis (JPEG, PNG ou WebP)');
    }

    const b = file.buffer;

    // Détection par magic bytes — plus fiable que le Content-Type header
    const isJpeg = b.length >= 3  && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
    const isPng  = b.length >= 4  && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
    const isWebp = b.length >= 12 &&
      b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && // RIFF
      b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50;  // WEBP

    if (!isJpeg && !isPng && !isWebp) {
      throw new BadRequestException(
        'Format image non supporté. Formats acceptés : JPEG, PNG, WebP',
      );
    }

    return this.intentExtractor.extractFromImage(b.toString('base64'), user.uid);
  }
}
