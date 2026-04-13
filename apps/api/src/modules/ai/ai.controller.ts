// apps/api/src/modules/ai/ai.controller.ts
//
// BUG 4 FIX A — Support WebP dans extractIntentFromImage
//
// PROBLÈME :
//   extractIntentFromImage() vérifiait uniquement JPEG et PNG via magic bytes.
//   WebP et HEIC (formats courants sur Android moderne et iOS) étaient rejetés
//   avec 400 BadRequest avant même d'atteindre le service.
//
// SOLUTION :
//   Ajouter la détection WebP (signature RIFF....WEBP sur les 12 premiers
//   octets). Gemini supporte nativement WebP — aucun changement côté service.

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

  /**
   * POST /ai/extract-intent/image — JPEG, PNG ou WebP
   *
   * BUG 4 FIX A :
   *   Ajout de la détection WebP (format Android courant).
   *   RIFF....WEBP : octets 0-3 = 52 49 46 46, octets 8-11 = 57 45 42 50.
   *   Gemini supporte nativement WebP via son API Files — aucune conversion
   *   nécessaire côté serveur.
   */
  @Post('extract-intent/image')
  @HttpCode(HttpStatus.OK)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 10 * 1024 * 1024 } }))
  async extractIntentFromImage(
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthUser,
  ): Promise<SearchIntent> {
    if (!file?.buffer?.length) throw new BadRequestException('Image file is required');

    const b = file.buffer;

    // JPEG : FF D8 FF
    const isJpeg = b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;

    // PNG : 89 50 4E 47
    const isPng =
      b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;

    // BUG 4 FIX A : WebP — RIFF....WEBP (12 premiers octets)
    // Format courant sur Android moderne (caméra, galerie) et Chrome.
    const isWebp =
      b.length >= 12 &&
      b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && // RIFF
      b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50;  // WEBP

    if (!isJpeg && !isPng && !isWebp) {
      throw new BadRequestException('Only JPEG, PNG, and WebP images are supported');
    }

    return this.intentExtractor.extractFromImage(b.toString('base64'), user.uid);
  }
}
