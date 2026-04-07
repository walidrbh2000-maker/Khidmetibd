import { Injectable, Logger } from '@nestjs/common';
import axios from 'axios';
import { AiProvider, AiTextOptions, AudioResult } from '../interfaces/ai-provider.interface';

interface VllmMessage {
  role: string;
  content: unknown[];
}

interface VllmResponse {
  choices: Array<{ message: { content: string } }>;
}

@Injectable()
export class VllmProvider extends AiProvider {
  private readonly logger     = new Logger(VllmProvider.name);
  private readonly baseUrl:   string;
  private readonly embedUrl:  string;
  private readonly model      = 'google/gemma-4-E4B-it';

  constructor() {
    super();
    this.baseUrl  = process.env['VLLM_BASE_URL']  ?? 'http://vllm:8000';
    // Embeddings via dedicated Ollama container (lighter than vLLM for embeds)
    this.embedUrl = process.env['OLLAMA_BASE_URL'] ?? 'http://ollama-embed:11434';
  }

  async generateText(
    prompt: string,
    systemPrompt: string,
    options: AiTextOptions = {},
  ): Promise<string> {
    try {
      const response = await axios.post<VllmResponse>(
        `${this.baseUrl}/v1/chat/completions`,
        {
          model:       this.model,
          temperature: options.temperature ?? 0.05,
          max_tokens:  options.maxTokens   ?? 300,
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user',   content: prompt },
          ],
        },
        { timeout: 15_000 },
      );
      return response.data.choices[0]?.message.content ?? '';
    } catch (err) {
      this.logger.error('VllmProvider.generateText failed', err);
      throw err;
    }
  }

  async analyzeImage(
    imageBase64: string,
    prompt: string,
    options: AiTextOptions = {},
  ): Promise<string> {
    try {
      // image BEFORE text — Gemma4 multimodal best practice
      const userContent: VllmMessage['content'] = [
        { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${imageBase64}` } },
        { type: 'text', text: prompt },
      ];
      const response = await axios.post<VllmResponse>(
        `${this.baseUrl}/v1/chat/completions`,
        {
          model:       this.model,
          temperature: options.temperature ?? 0.05,
          max_tokens:  options.maxTokens   ?? 300,
          messages:    [{ role: 'user', content: userContent }],
        },
        { timeout: 15_000 },
      );
      return response.data.choices[0]?.message.content ?? '';
    } catch (err) {
      this.logger.error('VllmProvider.analyzeImage failed', err);
      throw err;
    }
  }

  /**
   * vLLM native audio via --limit-mm-per-prompt audio=1.
   * No Whisper container needed — audio sent directly in input_audio block.
   * audio BEFORE text in content array (Gemma4 multimodal best practice).
   */
  async processAudio(
    audioBuffer: Buffer,
    mime: string,
    options: AiTextOptions = {},
  ): Promise<AudioResult> {
    try {
      const audioBase64 = audioBuffer.toString('base64');
      const format      = mime.split('/')[1] ?? 'm4a';
      const userContent: VllmMessage['content'] = [
        { type: 'input_audio', input_audio: { data: audioBase64, format } },
        { type: 'text', text: 'Transcribe this audio and return JSON: {"text": "<transcription>", "language": "<lang_code>"}' },
      ];
      const response = await axios.post<VllmResponse>(
        `${this.baseUrl}/v1/chat/completions`,
        {
          model:       this.model,
          temperature: options.temperature ?? 0.05,
          max_tokens:  options.maxTokens   ?? 500,
          messages:    [{ role: 'user', content: userContent }],
        },
        { timeout: 30_000 },
      );
      const raw = (response.data.choices[0]?.message.content ?? '').trim();
      try {
        return JSON.parse(raw) as { text: string; language: string };
      } catch {
        return { text: raw, language: 'auto' };
      }
    } catch (err) {
      this.logger.error('VllmProvider.processAudio failed', err);
      throw err;
    }
  }

  async generateEmbedding(text: string): Promise<number[]> {
    try {
      const response = await axios.post<{ embedding: number[] }>(
        `${this.embedUrl}/api/embeddings`,
        { model: 'nomic-embed-text', prompt: text },
        { timeout: 10_000 },
      );
      return response.data.embedding;
    } catch (err) {
      this.logger.error('VllmProvider.generateEmbedding failed', err);
      throw err;
    }
  }
}
