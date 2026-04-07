export interface AiTextOptions {
  temperature?: number;
  maxTokens?: number;
}

export interface AudioResult {
  text: string;
  language: string;
}

export abstract class AiProvider {
  abstract generateText(
    prompt: string,
    systemPrompt: string,
    options?: AiTextOptions,
  ): Promise<string>;

  abstract analyzeImage(
    imageBase64: string,
    prompt: string,
    options?: AiTextOptions,
  ): Promise<string>;

  abstract processAudio(
    audioBuffer: Buffer,
    mime: string,
    options?: AiTextOptions,
  ): Promise<AudioResult>;

  abstract generateEmbedding(text: string): Promise<number[]>;
}
