import { Injectable, Logger } from '@nestjs/common';
import axios from 'axios';
import FormData from 'form-data';
import { AiProvider, AiTextOptions, AudioResult } from '../interfaces/ai-provider.interface';

@Injectable()
export class OllamaProvider extends AiProvider {
  private readonly logger = new Logger(OllamaProvider.name);
  private readonly baseUrl: string;
  private readonly model: string;
  private readonly timeoutMs: number;
  private readonly whisperUrl: string;

  constructor() {
    super();
    this.baseUrl   = process.env['OLLAMA_BASE_URL']   ?? 'http://ollama:11434';
    this.model     = process.env['OLLAMA_MODEL']      ?? 'gemma4:e2b';
    this.timeoutMs = parseInt(process.env['OLLAMA_TIMEOUT_MS'] ?? '15000', 10);
    this.whisperUrl = process.env['WHISPER_BASE_URL'] ?? 'http://whisper:9000';
  }

  async generateText(
    prompt: string,
    systemPrompt: string,
    options: AiTextOptions = {},
  ): Promise<string> {
    try {
      const response = await axios.post<{ response: string }>(
        `${this.baseUrl}/api/generate`,
        {
          model:  this.model,
          system: systemPrompt,
          prompt,
          stream: false,
          options: {
            temperature: options.temperature ?? 0.05,
            num_predict: options.maxTokens   ?? 300,
          },
        },
        { timeout: this.timeoutMs },
      );
      return response.data.response;
    } catch (err) {
      this.logger.error('OllamaProvider.generateText failed', err);
      throw err;
    }
  }

  async analyzeImage(
    imageBase64: string,
    prompt: string,
    options: AiTextOptions = {},
  ): Promise<string> {
    try {
      // images[] BEFORE text — Gemma4 multimodal best practice
      const response = await axios.post<{ message: { content: string } }>(
        `${this.baseUrl}/api/chat`,
        {
          model:  this.model,
          stream: false,
          options: {
            temperature: options.temperature ?? 0.05,
            num_predict: options.maxTokens   ?? 300,
          },
          messages: [{
            role:    'user',
            content: prompt,
            images:  [imageBase64],
          }],
        },
        { timeout: this.timeoutMs },
      );
      return response.data.message.content;
    } catch (err) {
      this.logger.error('OllamaProvider.analyzeImage failed', err);
      throw err;
    }
  }

  /**
   * Ollama REST API does not support audio natively.
   * Delegates to the Whisper ASR container (onerahmet/openai-whisper-asr-webservice).
   */
  async processAudio(audioBuffer: Buffer, _mime: string): Promise<AudioResult> {
    try {
      const form = new FormData();
      form.append('audio_file', audioBuffer, {
        filename:    'audio.m4a',
        contentType: 'audio/m4a',
      });
      const response = await axios.post<{ text: string; language: string }>(
        `${this.whisperUrl}/asr?task=transcribe&language=auto&output=json`,
        form,
        { headers: form.getHeaders(), timeout: 30_000 },
      );
      return {
        text:     response.data.text     ?? '',
        language: response.data.language ?? 'auto',
      };
    } catch (err) {
      this.logger.error('OllamaProvider.processAudio (Whisper) failed', err);
      throw err;
    }
  }

  async generateEmbedding(text: string): Promise<number[]> {
    try {
      const response = await axios.post<{ embedding: number[] }>(
        `${this.baseUrl}/api/embeddings`,
        { model: 'nomic-embed-text', prompt: text },
        { timeout: this.timeoutMs },
      );
      return response.data.embedding;
    } catch (err) {
      this.logger.error('OllamaProvider.generateEmbedding failed', err);
      throw err;
    }
  }
}
