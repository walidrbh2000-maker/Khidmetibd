import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { Gemma4Provider, AudioResult } from '../providers/gemma4.provider';
import { QdrantService } from './qdrant.service';
import { AiRateLimitException } from '../exceptions/ai-provider.exception';
import type { Redis } from 'ioredis';

export interface SearchIntent {
  profession:           string | null;
  is_urgent:            boolean;
  problem_description:  string;
  max_radius_km:        number | null;
  confidence:           number;
  transcribedText?:     string;
}

const VALID_PROFESSIONS = new Set([
  'plumber','electrician','cleaner','painter','carpenter',
  'gardener','ac_repair','appliance_repair','mason','mechanic','mover',
]);

const FALLBACK: SearchIntent = {
  profession: null, is_urgent: false,
  problem_description: '', max_radius_km: null, confidence: 0,
};

const SYSTEM_PROMPT = `Tu es un extracteur d'intention pour Khidmeti, app algérienne de services à domicile.
Analyse en Darija/Arabe/Français/Anglais ou mélange.
Réponds UNIQUEMENT en JSON brut — aucun markdown.

Schema:
{"profession":<string|null>,"is_urgent":<bool>,"problem_description":<string>,"max_radius_km":<number|null>,"confidence":<number>}

Professions valides: plumber electrician cleaner painter carpenter gardener ac_repair appliance_repair mason mechanic mover

Darija: "ماء ساقط"→plumber | "الضوء طاح"→electrician | "الكليماتيزور ما يبردش"→ac_repair
        "صنفارية مسدودة"→plumber | "الفريج خربان"→appliance_repair | "الباب ما يقفلش"→carpenter

Règles:
- is_urgent: true SEULEMENT inondation/coupure totale/fuite gaz/serrure cassée la nuit
- problem_description: anglais factuel, max 120 chars
- confidence: 0.0–1.0`;

@Injectable()
export class IntentExtractorService {
  private readonly logger   = new Logger(IntentExtractorService.name);
  private readonly cache    = new Map<string, SearchIntent>();
  private readonly MAX_CACHE        = 20;
  private readonly RATE_LIMIT_MAX   = 20;
  private readonly RATE_LIMIT_WINDOW = 3_600_000;

  constructor(
    private readonly gemma4: Gemma4Provider,
    private readonly qdrant: QdrantService,
    @Optional() @Inject('REDIS_CLIENT') private readonly redis?: Redis,
  ) {}

  async extractFromText(text: string, uid?: string): Promise<SearchIntent> {
    const trimmed = text.trim().slice(0, 2000);
    if (!trimmed) return { ...FALLBACK };

    if (uid) await this.checkRateLimit(uid);

    const cached = this.cache.get(trimmed.toLowerCase());
    if (cached) return cached;

    const embedding  = await this.gemma4.generateEmbedding(trimmed);
    const candidates = await this.qdrant.search('service_descriptions', embedding, 5);
    const context    = candidates
      .map((c) => c.payload['exampleText'] as string ?? '')
      .filter(Boolean).join('\n');

    const prompt = context
      ? `Exemples:\n${context}\n\nRequête: ${trimmed}`
      : trimmed;

    const raw    = await this.gemma4.generateText(prompt, SYSTEM_PROMPT);
    const intent = this.parse(raw);
    this.setCache(trimmed.toLowerCase(), intent);
    return intent;
  }

  async extractFromAudio(buffer: Buffer, mime: string, uid?: string): Promise<SearchIntent> {
    const { text, language } = await this.gemma4.processAudio(buffer, mime);
    if (!text.trim()) return { ...FALLBACK };
    this.logger.debug(`Audio [${language}]: ${text}`);
    return { ...(await this.extractFromText(text, uid)), transcribedText: text };
  }

  async extractFromImage(imageBase64: string, uid?: string): Promise<SearchIntent> {
    if (uid) await this.checkRateLimit(uid);
    const raw = await this.gemma4.analyzeImage(
      imageBase64,
      'Identifie le problème domestique dans cette image. ' + SYSTEM_PROMPT,
    );
    return this.parse(raw);
  }

  private parse(raw: string): SearchIntent {
    const s = raw.replace(/```json|```/g, '').trim();
    const i = s.indexOf('{'), j = s.lastIndexOf('}');
    if (i === -1 || j === -1) return { ...FALLBACK };
    try {
      const p = JSON.parse(s.slice(i, j + 1)) as Partial<SearchIntent>;
      return {
        profession:          typeof p.profession === 'string' && VALID_PROFESSIONS.has(p.profession) ? p.profession : null,
        is_urgent:           p.is_urgent === true,
        problem_description: (p.problem_description ?? '').slice(0, 120),
        max_radius_km:       typeof p.max_radius_km === 'number' ? p.max_radius_km : null,
        confidence:          typeof p.confidence    === 'number' ? Math.min(1, Math.max(0, p.confidence)) : 0,
      };
    } catch { return { ...FALLBACK }; }
  }

  private setCache(key: string, intent: SearchIntent): void {
    if (this.cache.size >= this.MAX_CACHE) {
      this.cache.delete(this.cache.keys().next().value as string);
    }
    this.cache.set(key, intent);
  }

  private async checkRateLimit(uid: string): Promise<void> {
    if (!this.redis) return;
    const key = `ai_rate:${uid}`, now = Date.now();
    try {
      const p = this.redis.pipeline();
      p.zremrangebyscore(key, '-inf', now - this.RATE_LIMIT_WINDOW);
      p.zcard(key);
      p.zadd(key, now, `${now}`);
      p.expire(key, 3600);
      const r = await p.exec();
      if (((r?.[1]?.[1] as number) ?? 0) >= this.RATE_LIMIT_MAX) {
        await this.redis.zrem(key, `${now}`);
        throw new AiRateLimitException();
      }
    } catch (e) {
      if (e instanceof AiRateLimitException) throw e;
      this.logger.warn(`Redis rate-limit dégradé: ${e}`);
    }
  }
}
