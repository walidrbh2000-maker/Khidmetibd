// lib/services/ai_intent_extractor.dart

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

import '../models/search_intent.dart';
import '../utils/app_config.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';

/// Structured error codes — consumed by HomeSearchController to display
/// distinct messages per failure mode rather than a generic fallback.
enum AiExtractorErrorCode {
  quotaExceeded,    // HTTP 429 — rate limit reached
  modelOverloaded,  // HTTP 503 — server temporarily overloaded
  timeout,          // hard 15s timeout exceeded
  network,          // generic network / SDK error
  parse,            // JSON parsing failure
  invalidInput,     // empty input validation
  alreadyProcessing,// _isBusy guard fired
}

class AiIntentExtractorException implements Exception {
  final String              message;
  final AiExtractorErrorCode code;
  const AiIntentExtractorException(
    this.message, {
    this.code = AiExtractorErrorCode.network,
  });

  @override
  String toString() => 'AiIntentExtractorException[$code]: $message';
}

class AiIntentExtractorService {
  static const String   _modelName   = 'gemini-2.5-flash-lite';
  static const Duration _callTimeout = Duration(seconds: 15);

  // FIX (AI Cost): LRU cache for text-only queries.
  // Capacity: 20 entries. Evicts least-recently-used on overflow.
  static const int _cacheCapacity = 20;
  final _cache = LinkedHashMap<String, SearchIntent>(
    equals:   (a, b) => a == b,
    hashCode: (k) => k.hashCode,
  );

  SearchIntent? _getCached(String key) {
    final entry = _cache[key];
    if (entry != null) {
      _cache.remove(key);
      _cache[key] = entry; // move to end (MRU)
    }
    return entry;
  }

  void _putCache(String key, SearchIntent value) {
    if (_cache.length >= _cacheCapacity) {
      _cache.remove(_cache.keys.first); // evict LRU
    }
    _cache[key] = value;
  }

  static const String _systemPrompt = '''
You are an intent extractor for Khidmeti, an Algerian home services app.
Your ONLY job is to analyze the user's home problem description (which may be
in French, Arabic, Algerian Darija, or English, or any mix) and return a JSON object.

CRITICAL: Respond with ONLY raw JSON. No markdown, no code fences, no explanations.

LANGUAGE: Algerian Darija is the primary language of this app's users — handle it
natively without translation. Understand expressions like "ماء ساقط", "الضوء طاح",
"الكليماتيزور ما يبردش", "صنفارية مسدودة", "الفريج خربان", "الباب ما يقفلش".

STT CORRECTION: The input may come from voice speech recognition and contain
misrecognized words. Infer the correct trade from overall context even if individual
words are wrong. Example: "plan B" or "plam beer" → plumber, "electric city" → electrician,
"clim" or "clim ma tberdch" → ac_repair. Prioritize semantic meaning over exact wording.

JSON schema (required, exact structure):
{
  "profession": "<string | null>",
  "is_urgent": <boolean>,
  "problem_description": "<string>",
  "max_radius_km": <number | null>,
  "confidence": <number>
}

Valid profession values — use EXACTLY one of these strings or null:
plumber, electrician, cleaner, painter, carpenter, gardener,
ac_repair, appliance_repair, mason, mechanic, mover

Rules:
- profession: the single most appropriate trade. null if unclear.
- is_urgent: true ONLY for genuine emergencies — flooding, complete power outage, gas leak, fire risk, broken lock at night. Default false.
- problem_description: concise factual English description, max 120 characters.
- max_radius_km: null unless user explicitly requests a distance.
- confidence: 0.0 to 1.0.

Examples:
Input: "j'ai une fuite d'eau sous l'évier"
Output: {"profession":"plumber","is_urgent":false,"problem_description":"water leak under the kitchen sink","max_radius_km":null,"confidence":0.97}

Input: "الكهرباء انقطعت كاملاً من البيت"
Output: {"profession":"electrician","is_urgent":true,"problem_description":"complete power outage in the house","max_radius_km":null,"confidence":0.99}
''';

  late final GenerativeModel _model;

  bool _isBusy = false;
  bool get isBusy => _isBusy;

  AiIntentExtractorService() {
    _model = GenerativeModel(
      model:   _modelName,
      apiKey:  AppConfig.geminiApiKey,
      generationConfig: GenerationConfig(
        temperature:     0.05,
        maxOutputTokens: 300,
        topP:            0.95,
        topK:            40,
      ),
      systemInstruction: Content.system(_systemPrompt),
    );
  }

  /// Extracts a [SearchIntent] from [text] and/or [imageBytes].
  Future<SearchIntent> extract(
    String text, {
    Uint8List? imageBytes,
    String?    mime,
  }) async {
    final hasText  = text.trim().isNotEmpty;
    final hasImage = imageBytes != null && imageBytes.isNotEmpty;

    if (!hasText && !hasImage) {
      throw const AiIntentExtractorException(
        'No input provided',
        code: AiExtractorErrorCode.invalidInput,
      );
    }

    if (_isBusy) {
      AppLogger.warning('AiIntentExtractor: call rejected — already processing');
      throw const AiIntentExtractorException(
        'Already processing a request',
        code: AiExtractorErrorCode.alreadyProcessing,
      );
    }

    // FIX (AI Cost): serve cached result for identical text-only queries.
    if (hasText && !hasImage) {
      final cacheKey    = text.trim().toLowerCase();
      final cachedResult = _getCached(cacheKey);
      if (cachedResult != null) {
        AppLogger.debug('AiIntentExtractor: cache hit for "$cacheKey"');
        return cachedResult;
      }
    }

    _isBusy = true;
    AppLogger.info('AiIntentExtractor: processing'
        '${hasText ? " text" : ""}'
        '${hasImage ? " + image" : ""}');

    final parts = <Part>[];
    if (hasImage) {
      parts.add(DataPart(_resolveMime(mime, imageBytes!), imageBytes));
    }
    if (hasText) {
      parts.add(TextPart(text.trim()));
    } else {
      parts.add(TextPart('Analyze this image to identify the home maintenance problem.'));
    }

    try {
      final response = await _model
          .generateContent([Content.multi(parts)])
          .timeout(
            _callTimeout,
            onTimeout: () => throw const AiIntentExtractorException(
              'Request timed out — please try again',
              code: AiExtractorErrorCode.timeout,
            ),
          );

      final raw    = response.text?.trim() ?? '';
      AppLogger.debug('AiIntentExtractor: raw → $raw');
      final result = _parse(raw);

      if (hasText && !hasImage) {
        _putCache(text.trim().toLowerCase(), result);
      }

      return result;
    } on AiIntentExtractorException {
      rethrow;
    } catch (e) {
      AppLogger.error('AiIntentExtractor.extract', e);
      throw _classifyError(e);
    } finally {
      _isBusy = false;
    }
  }

  /// Extracts a [SearchIntent] directly from raw audio bytes.
  /// Token cost: ~32 tokens/second of audio. 15s ≈ 580 tokens total.
  Future<SearchIntent> extractFromAudio(
    Uint8List audioBytes, {
    String mime = 'audio/m4a',
  }) async {
    if (audioBytes.isEmpty) {
      throw const AiIntentExtractorException(
        'Audio bytes are empty',
        code: AiExtractorErrorCode.invalidInput,
      );
    }

    if (_isBusy) {
      AppLogger.warning('AiIntentExtractor: call rejected — already processing');
      throw const AiIntentExtractorException(
        'Already processing a request',
        code: AiExtractorErrorCode.alreadyProcessing,
      );
    }

    _isBusy = true;
    AppLogger.info('AiIntentExtractor: processing audio ${audioBytes.length} bytes');

    const audioPrompt = 'Algerian home services voice query.';
    final parts = <Part>[DataPart(mime, audioBytes), TextPart(audioPrompt)];

    try {
      final response = await _model
          .generateContent([Content.multi(parts)])
          .timeout(
            _callTimeout,
            onTimeout: () => throw const AiIntentExtractorException(
              'Audio request timed out — please try again',
              code: AiExtractorErrorCode.timeout,
            ),
          );

      final raw = response.text?.trim() ?? '';
      AppLogger.debug('AiIntentExtractor [audio]: raw → $raw');
      return _parse(raw);
    } on AiIntentExtractorException {
      rethrow;
    } catch (e) {
      AppLogger.error('AiIntentExtractor.extractFromAudio', e);
      throw _classifyError(e);
    } finally {
      _isBusy = false;
    }
  }

  // FIX (AI Cost): classify Gemini SDK exceptions into structured error codes
  // so the UI layer can show distinct, user-friendly messages.
  AiIntentExtractorException _classifyError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('429') || msg.contains('quota') ||
        msg.contains('rate limit')) {
      return AiIntentExtractorException(
        'Quota exceeded — please retry in a few minutes',
        code: AiExtractorErrorCode.quotaExceeded,
      );
    }
    if (msg.contains('503') || msg.contains('overload') ||
        msg.contains('unavailable')) {
      return AiIntentExtractorException(
        'Model temporarily overloaded — please retry',
        code: AiExtractorErrorCode.modelOverloaded,
      );
    }
    return AiIntentExtractorException(
      'Gemini API error: $e',
      code: AiExtractorErrorCode.network,
    );
  }

  String _resolveMime(String? mime, Uint8List bytes) {
    if (mime != null && mime.trim().isNotEmpty) return mime;
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4E && bytes[3] == 0x47) {
      return 'image/png';
    }
    return 'image/jpeg';
  }

  SearchIntent _parse(String raw) {
    String s = raw
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .trim();

    final start = s.indexOf('{');
    final end   = s.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      AppLogger.warning('AiIntentExtractor: no JSON object found — using fallback');
      return const SearchIntent();
    }

    s = s.substring(start, end + 1);

    try {
      final json = jsonDecode(s) as Map<String, dynamic>;
      return SearchIntent.fromJson(json);
    } catch (e) {
      AppLogger.error('AiIntentExtractor._parse', e);
      return const SearchIntent();
    }
  }
}
