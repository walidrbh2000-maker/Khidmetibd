/**
 * Gemma4Provider — Google AI API (@google/genai v1.x)
 *
 * Fix: ThinkingMode n'existe pas dans @google/genai v1.0.0 (enum interne non exporté).
 *      thinkingConfig retiré — le modèle raisonne par défaut avec gemma-4-31b-it.
 *      Interface publique inchangée — aucun autre fichier à modifier.
 */

import { Injectable, Logger } from '@nestjs/common';
import { GoogleGenAI } from '@google/genai';
import type { Content, Part, GenerateContentConfig } from '@google/genai';

export interface AudioResult {
  text:     string;
  language: string;
}

@Injectable()
export class Gemma4Provider {
  private readonly logger = new Logger(Gemma4Provider.name);
  private readonly ai: GoogleGenAI;

  private readonly MODEL:      string;
  private readonly EMBED_MODEL = 'text-embedding-004'; // 768-dim

  constructor() {
    const apiKey = process.env['GEMINI_API_KEY'];
    if (!apiKey) throw new Error('GEMINI_API_KEY manquante');

    this.MODEL = process.env['GEMMA4_MODEL'] ?? 'gemma-4-31b-it';
    this.ai    = new GoogleGenAI({ apiKey });

    this.logger.log(`✅ Gemma4Provider — modèle: ${this.MODEL}`);
  }

  // ── Texte ────────────────────────────────────────────────────────────────────

  async generateText(
    prompt:       string,
    systemPrompt: string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const config: GenerateContentConfig = {
      systemInstruction: systemPrompt,
      temperature:       opts.temperature ?? 0.05,
      maxOutputTokens:   opts.maxTokens   ?? 600,
      tools:             [{ googleSearch: {} }],
    };

    const response = await this.ai.models.generateContent({
      model:    this.MODEL,
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      config,
    });

    return response.text ?? '';
  }

  // ── Image ────────────────────────────────────────────────────────────────────

  async analyzeImage(
    imageBase64: string,
    prompt:      string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<string> {
    const contents: Content[] = [{
      role:  'user',
      parts: [
        { inlineData: { data: imageBase64, mimeType: 'image/jpeg' } } as Part,
        { text: prompt },
      ],
    }];

    const response = await this.ai.models.generateContent({
      model:    this.MODEL,
      contents,
      config: {
        temperature:     opts.temperature ?? 0.05,
        maxOutputTokens: opts.maxTokens   ?? 600,
      },
    });

    return response.text ?? '';
  }

  // ── Audio ────────────────────────────────────────────────────────────────────

  async processAudio(
    audioBuffer: Buffer,
    mime:        string,
    opts: { temperature?: number; maxTokens?: number } = {},
  ): Promise<AudioResult> {
    const contents: Content[] = [{
      role:  'user',
      parts: [
        { inlineData: { data: audioBuffer.toString('base64'), mimeType: mime } } as Part,
        { text: 'Transcris cet audio. Réponds UNIQUEMENT en JSON brut sans markdown:\n{"text":"<transcription>","language":"<code_langue>"}' },
      ],
    }];

    const response = await this.ai.models.generateContent({
      model:    this.MODEL,
      contents,
      config: {
        temperature:     opts.temperature ?? 0.05,
        maxOutputTokens: opts.maxTokens   ?? 500,
      },
    });

    const raw = (response.text ?? '').trim().replace(/```json|```/g, '').trim();
    try {
      return JSON.parse(raw) as AudioResult;
    } catch {
      return { text: raw, language: 'auto' };
    }
  }

  // ── Embedding ────────────────────────────────────────────────────────────────

  async generateEmbedding(text: string): Promise<number[]> {
    const response = await this.ai.models.embedContent({
      model:    this.EMBED_MODEL,
      contents: [{ role: 'user', parts: [{ text }] }],
    });
    return response.embeddings?.[0]?.values ?? [];
  }
}
