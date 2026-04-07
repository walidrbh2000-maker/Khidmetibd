import { Injectable, Logger } from '@nestjs/common';
import {
  GoogleGenerativeAI,
  GenerativeModel,
  Part,
} from '@google/generative-ai';
import { AiProvider, AiTextOptions, AudioResult } from '../interfaces/ai-provider.interface';

@Injectable()
export class GeminiProvider extends AiProvider {
  private readonly logger = new Logger(GeminiProvider.name);
  private readonly client: GoogleGenerativeAI;
  private readonly textModel: GenerativeModel;
  private readonly embedModel: GenerativeModel;

  constructor() {
    super();
    const apiKey = process.env['GEMINI_API_KEY'];
    if (!apiKey) throw new Error('GEMINI_API_KEY is required when AI_PROVIDER=gemini');
    this.client = new GoogleGenerativeAI(apiKey);
    this.textModel = this.client.getGenerativeModel({ model: 'gemini-2.0-flash' });
    this.embedModel = this.client.getGenerativeModel({ model: 'models/text-embedding-004' });
  }

  async generateText(
    prompt: string,
    systemPrompt: string,
    options: AiTextOptions = {},
  ): Promise<string> {
    try {
      const model = this.client.getGenerativeModel({
        model: 'gemini-2.0-flash',
        systemInstruction: systemPrompt,
        generationConfig: {
          temperature: options.temperature ?? 0.05,
          maxOutputTokens: options.maxTokens ?? 300,
        },
      });
      const result = await model.generateContent(prompt);
      return result.response.text();
    } catch (err) {
      this.logger.error('GeminiProvider.generateText failed', err);
      throw err;
    }
  }

  async analyzeImage(
    imageBase64: string,
    prompt: string,
    options: AiTextOptions = {},
  ): Promise<string> {
    try {
      const model = this.client.getGenerativeModel({
        model: 'gemini-2.0-flash',
        generationConfig: {
          temperature: options.temperature ?? 0.05,
          maxOutputTokens: options.maxTokens ?? 300,
        },
      });
      // Image BEFORE text (Gemma4 multimodal best practice)
      const imagePart: Part = {
        inlineData: { data: imageBase64, mimeType: 'image/jpeg' },
      };
      const result = await model.generateContent([imagePart, { text: prompt }]);
      return result.response.text();
    } catch (err) {
      this.logger.error('GeminiProvider.analyzeImage failed', err);
      throw err;
    }
  }

  async processAudio(
    audioBuffer: Buffer,
    mime: string,
    options: AiTextOptions = {},
  ): Promise<AudioResult> {
    try {
      const model = this.client.getGenerativeModel({
        model: 'gemini-2.0-flash',
        generationConfig: {
          temperature: options.temperature ?? 0.05,
          maxOutputTokens: options.maxTokens ?? 500,
        },
      });
      const audioPart: Part = {
        inlineData: { data: audioBuffer.toString('base64'), mimeType: mime },
      };
      const result = await model.generateContent([
        audioPart,
        { text: 'Transcribe this audio and return JSON: {"text": "<transcription>", "language": "<language_code>"}' },
      ]);
      const raw = result.response.text().trim();
      try {
        const parsed = JSON.parse(raw) as { text: string; language: string };
        return parsed;
      } catch {
        return { text: raw, language: 'auto' };
      }
    } catch (err) {
      this.logger.error('GeminiProvider.processAudio failed', err);
      throw err;
    }
  }

  async generateEmbedding(text: string): Promise<number[]> {
    try {
      const result = await this.embedModel.embedContent(text);
      return result.embedding.values;
    } catch (err) {
      this.logger.error('GeminiProvider.generateEmbedding failed', err);
      throw err;
    }
  }
}
