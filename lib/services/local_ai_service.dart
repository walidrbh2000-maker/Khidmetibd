// lib/services/local_ai_service.dart
//
// STEP 5 MIGRATION: Replaces AiIntentExtractorService.
//
// PATCH — Bug 2 fix (photo search):
//   - _extractWithImage: ContentType explicite via http_parser MediaType
//   - _detectImageMime: détection depuis magic bytes (pur Dart)
//
// PATCH — Bug 3 fix (audio intermittent):
//   - _isBusy scindé en _isBusyText + _isBusyAudio (isolation)
//   - extractFromAudio: retry x2 sur 5xx/timeout
//   - ContentType explicite sur le multipart audio

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/search_intent.dart';

// ── Re-export error types so callers keep identical imports ──────────────────

enum AiExtractorErrorCode {
  quotaExceeded,
  modelOverloaded,
  timeout,
  network,
  parse,
  invalidInput,
  alreadyProcessing,
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

// ─────────────────────────────────────────────────────────────────────────────

class LocalAiService {
  final String      _baseUrl;
  final http.Client _http;

  static const Duration _callTimeout     = Duration(seconds: 15);
  static const int      _cacheCapacity   = 20;
  static const int      _maxCallsPerHour = 20;

  // BUG 3 FIX: scinder en deux pour ne pas bloquer l'audio quand une
  // requête image/texte est en cours (et vice-versa).
  bool _isBusyText  = false; // garde pour extract() text + image
  bool _isBusyAudio = false; // garde pour extractFromAudio()

  bool get isBusy => _isBusyText || _isBusyAudio;

  // LRU cache (text-only queries)
  final _cache = LinkedHashMap<String, SearchIntent>(
    equals:   (a, b) => a == b,
    hashCode: (k) => k.hashCode,
  );

  // Rate limiter
  final List<DateTime> _callTimestamps = [];

  LocalAiService({required String baseUrl, http.Client? httpClient})
      : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _http    = httpClient ?? http.Client();

  // ── Cache helpers ──────────────────────────────────────────────────────────

  SearchIntent? _getCached(String key) {
    final entry = _cache[key];
    if (entry != null) {
      _cache.remove(key);
      _cache[key] = entry;
    }
    return entry;
  }

  void _putCache(String key, SearchIntent value) {
    if (_cache.length >= _cacheCapacity) _cache.remove(_cache.keys.first);
    _cache[key] = value;
  }

  // ── Rate limiter ───────────────────────────────────────────────────────────

  bool _isRateLimited() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    _callTimestamps.removeWhere((t) => t.isBefore(cutoff));
    return _callTimestamps.length >= _maxCallsPerHour;
  }

  void _recordCall() => _callTimestamps.add(DateTime.now());

  // ── Auth header ────────────────────────────────────────────────────────────

  Future<String?> _getToken() async =>
      FirebaseAuth.instance.currentUser?.getIdToken();

  // ═══════════════════════════════════════════════════════════════════════════
  // Public API — identical signatures to AiIntentExtractorService
  // ═══════════════════════════════════════════════════════════════════════════

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

    // BUG 3 FIX: utiliser _isBusyText uniquement (pas _isBusyAudio)
    if (_isBusyText) {
      throw const AiIntentExtractorException(
        'Already processing a request',
        code: AiExtractorErrorCode.alreadyProcessing,
      );
    }

    if (_isRateLimited()) {
      throw const AiIntentExtractorException(
        'Rate limit exceeded — max 20 requests per hour',
        code: AiExtractorErrorCode.quotaExceeded,
      );
    }

    if (hasText && !hasImage) {
      final cacheKey     = text.trim().toLowerCase();
      final cachedResult = _getCached(cacheKey);
      if (cachedResult != null) return cachedResult;
    }

    _isBusyText = true;
    try {
      SearchIntent result;
      if (hasImage) {
        result = await _extractWithImage(text, imageBytes!, mime);
      } else {
        result = await _extractText(text);
      }
      if (hasText && !hasImage) _putCache(text.trim().toLowerCase(), result);
      _recordCall();
      return result;
    } finally {
      _isBusyText = false;
    }
  }

  /// Extracts a [SearchIntent] from raw audio bytes.
  /// BUG 3 FIX: retry x2 sur 5xx/timeout + _isBusyAudio séparé.
  Future<SearchIntent> extractFromAudio(
    Uint8List audioBytes, {
    String mime       = 'audio/m4a',
    int    maxRetries = 2,
  }) async {
    if (audioBytes.isEmpty) {
      throw const AiIntentExtractorException(
        'Audio bytes are empty',
        code: AiExtractorErrorCode.invalidInput,
      );
    }

    // BUG 3 FIX: garde audio indépendante de la garde texte/image
    if (_isBusyAudio) {
      throw const AiIntentExtractorException(
        'Already processing an audio request',
        code: AiExtractorErrorCode.alreadyProcessing,
      );
    }

    if (_isRateLimited()) {
      throw const AiIntentExtractorException(
        'Rate limit exceeded',
        code: AiExtractorErrorCode.quotaExceeded,
      );
    }

    _isBusyAudio = true;
    Exception? lastError;

    try {
      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          final token   = await _getToken();
          final request = http.MultipartRequest(
            'POST',
            Uri.parse('$_baseUrl/ai/extract-intent/audio'),
          );
          if (token != null) request.headers['Authorization'] = 'Bearer $token';

          // BUG 3 FIX: MediaType explicite pour éviter application/octet-stream
          request.files.add(http.MultipartFile.fromBytes(
            'file',
            audioBytes,
            filename:    'audio.m4a',
            contentType: MediaType.parse(mime),
          ));

          final streamed = await request.send().timeout(_callTimeout);
          final response = await http.Response.fromStream(streamed);

          // Retry sur erreur 5xx transitoire (503 overload, 502 gateway)
          if (response.statusCode >= 500 && attempt < maxRetries) {
            if (kDebugMode) {
              debugPrint('[LocalAiService] Audio attempt $attempt failed '
                  '(${response.statusCode}), retrying...');
            }
            await Future.delayed(Duration(seconds: attempt));
            continue;
          }

          _recordCall();
          return _parseResponse(response);

        } on AiIntentExtractorException {
          rethrow; // quota/overload → pas de retry
        } on TimeoutException {
          lastError = const AiIntentExtractorException(
            'Audio request timed out',
            code: AiExtractorErrorCode.timeout,
          );
          if (attempt < maxRetries) {
            await Future.delayed(const Duration(seconds: 2));
          }
        } catch (e) {
          lastError = _classifyError(e);
          if (attempt < maxRetries) {
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }

      throw lastError ??
          const AiIntentExtractorException(
            'Audio extraction failed after retries',
            code: AiExtractorErrorCode.network,
          );
    } finally {
      _isBusyAudio = false;
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  Future<SearchIntent> _extractText(String text) async {
    final token    = await _getToken();
    final response = await _http.post(
      Uri.parse('$_baseUrl/ai/extract-intent'),
      headers: {
        'Content-Type':  'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'text': text.trim()}),
    ).timeout(_callTimeout);
    return _parseResponse(response);
  }

  /// BUG 2 FIX: ContentType explicite depuis magic bytes.
  Future<SearchIntent> _extractWithImage(
      String text, Uint8List imageBytes, String? mime) async {
    // Détecter le vrai MIME depuis les magic bytes (plus fiable que le param)
    final detectedMime = _detectImageMime(imageBytes) ?? mime ?? 'image/jpeg';
    final extension    = detectedMime == 'image/png' ? 'png' : 'jpg';

    final token   = await _getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/ai/extract-intent/image'),
    );
    if (token != null) request.headers['Authorization'] = 'Bearer $token';

    // BUG 2 FIX: MediaType explicite — évite application/octet-stream
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      imageBytes,
      filename:    'image.$extension',
      contentType: MediaType.parse(detectedMime),
    ));

    // Contexte textuel optionnel (aide Gemini à identifier le problème)
    if (text.trim().isNotEmpty) {
      request.fields['text'] = text.trim();
    }

    final streamed = await request.send().timeout(_callTimeout);
    final response = await http.Response.fromStream(streamed);
    return _parseResponse(response);
  }

  /// BUG 2 FIX: Détection MIME depuis magic bytes — évite application/octet-stream.
  String? _detectImageMime(Uint8List bytes) {
    if (bytes.length < 4) return null;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4E && bytes[3] == 0x47) {
      return 'image/png';
    }
    // WebP: RIFF....WEBP
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 &&
        bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 &&
        bytes[10] == 0x42 && bytes[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  SearchIntent _parseResponse(http.Response response) {
    if (response.statusCode == 429) {
      throw const AiIntentExtractorException(
        'Quota exceeded — retry in a few minutes',
        code: AiExtractorErrorCode.quotaExceeded,
      );
    }
    if (response.statusCode == 503) {
      throw const AiIntentExtractorException(
        'Model temporarily overloaded — retry',
        code: AiExtractorErrorCode.modelOverloaded,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiIntentExtractorException(
        'Server error (${response.statusCode})',
        code: AiExtractorErrorCode.network,
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      // NestJS ResponseInterceptor wraps: { success, data, timestamp }
      final Map<String, dynamic> json;
      if (decoded is Map && decoded['success'] == true && decoded.containsKey('data')) {
        json = (decoded['data'] as Map).cast<String, dynamic>();
      } else if (decoded is Map) {
        json = decoded.cast<String, dynamic>();
      } else {
        return const SearchIntent();
      }
      return SearchIntent.fromJson(json);
    } catch (e) {
      throw AiIntentExtractorException(
        'Parse error: $e',
        code: AiExtractorErrorCode.parse,
      );
    }
  }

  AiIntentExtractorException _classifyError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('429') || msg.contains('quota') || msg.contains('rate limit')) {
      return const AiIntentExtractorException(
          'Quota exceeded', code: AiExtractorErrorCode.quotaExceeded);
    }
    if (msg.contains('503') || msg.contains('overload') || msg.contains('unavailable')) {
      return const AiIntentExtractorException(
          'Model overloaded', code: AiExtractorErrorCode.modelOverloaded);
    }
    if (msg.contains('timeout') || msg.contains('timed out')) {
      return const AiIntentExtractorException(
          'Request timed out', code: AiExtractorErrorCode.timeout);
    }
    return AiIntentExtractorException(
        'Network error: $e', code: AiExtractorErrorCode.network);
  }

  void dispose() {
    _cache.clear();
    _callTimestamps.clear();
    _http.close();
  }
}
