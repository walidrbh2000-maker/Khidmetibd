import { Injectable, Logger } from '@nestjs/common';
import axios from 'axios';
import FormData from 'form-data';

export interface TranscriptionResult {
  text: string;
  language: string;
}

/**
 * WhisperService delegates audio transcription to the
 * onerahmet/openai-whisper-asr-webservice container.
 * Used by OllamaProvider because the Ollama REST API
 * does not support audio natively.
 */
@Injectable()
export class WhisperService {
  private readonly logger     = new Logger(WhisperService.name);
  private readonly baseUrl:   string;
  private readonly timeoutMs: number;

  constructor() {
    this.baseUrl   = process.env['WHISPER_BASE_URL'] ?? 'http://whisper:9000';
    this.timeoutMs = 30_000;
  }

  async transcribeAudio(
    audioBuffer: Buffer,
    language = 'auto',
    filename  = 'audio.m4a',
    mimeType  = 'audio/m4a',
  ): Promise<TranscriptionResult> {
    try {
      const form = new FormData();
      form.append('audio_file', audioBuffer, { filename, contentType: mimeType });

      const response = await axios.post<{ text: string; language: string }>(
        `${this.baseUrl}/asr?task=transcribe&language=${language}&output=json`,
        form,
        { headers: form.getHeaders(), timeout: this.timeoutMs },
      );

      return {
        text:     response.data.text     ?? '',
        language: response.data.language ?? 'auto',
      };
    } catch (err) {
      this.logger.error('WhisperService.transcribeAudio failed', err);
      throw err;
    }
  }
}
