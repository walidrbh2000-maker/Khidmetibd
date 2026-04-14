// lib/services/local_media_service.dart
//
// MIGRATION — NestJS comme proxy MinIO
//
// CHANGEMENT PRINCIPAL :
//   Les méthodes uploadImage / uploadVideo / uploadAudio retournent maintenant
//   un UploadResult contenant DEUX champs :
//
//     url        → URL proxy NestJS complète (utilisation immédiate)
//     storedPath → "bucket/userId/file.ext" (PERSISTER CECI en base)
//
//   AVANT : _upload() retournait Future<String> (l'URL presigned MinIO)
//   APRÈS : _upload() retourne Future<UploadResult>
//
// POURQUOI storedPath ?
//   Le tunnel Cloudflare change de domaine régulièrement.
//   Stocker l'URL complète en base → toutes les URLs cassées dès le changement.
//   Stocker storedPath → MediaPathHelper.toUrl(storedPath, apiBaseUrl: url_courante)
//   reconstruit l'URL correcte à chaque affichage, quel que soit le domaine.
//
// RÉTROCOMPATIBILITÉ :
//   CloudinaryServiceException est conservée (même nom, même interface) pour
//   ne pas casser les call sites existants qui importent cette exception.

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

// ── UploadResult ──────────────────────────────────────────────────────────────

/// Résultat d'un upload vers le backend NestJS / MinIO.
///
/// USAGE :
///   ```dart
///   final result = await localMediaService.uploadImage(file);
///
///   // ✅ Persister en base de données :
///   mediaUrls.add(result.storedPath);
///
///   // ✅ Afficher immédiatement (URL valable maintenant) :
///   Image.network(result.url)
///
///   // ✅ Afficher de manière durable (survit au changement de domaine) :
///   Image.network(MediaPathHelper.toUrl(result.storedPath, apiBaseUrl: _baseUrl))
///   ```
class UploadResult {
  /// URL proxy NestJS complète — valable immédiatement, dépendante du domaine.
  /// Ex: "https://xyz.trycloudflare.com/media/object/service-media/abc/file.jpg"
  ///
  /// NE PAS persister en base : change avec chaque tunnel Cloudflare.
  final String url;

  /// Chemin durable : "bucket/userId/timestamp_uuid.ext".
  /// Ex: "service-media/abc123/1715000000_550e8400.jpg"
  ///
  /// PERSISTER CE CHAMP dans MongoDB.
  /// Utiliser MediaPathHelper.toUrl(storedPath, apiBaseUrl: …) pour afficher.
  final String storedPath;

  const UploadResult({
    required this.url,
    required this.storedPath,
  });

  @override
  String toString() => 'UploadResult(storedPath: $storedPath, url: $url)';
}

// ── Exception (rétrocompatibilité) ────────────────────────────────────────────
// Le nom CloudinaryServiceException est conservé pour ne pas casser les imports
// existants dans MediaService et autres call sites.

export 'local_media_service.dart' show CloudinaryServiceException;

class CloudinaryServiceException implements Exception {
  final String  message;
  final String? code;
  final dynamic originalError;

  const CloudinaryServiceException(this.message, {this.code, this.originalError});

  @override
  String toString() =>
      'CloudinaryServiceException: $message${code != null ? ' ($code)' : ''}';
}

// ── LocalMediaService ─────────────────────────────────────────────────────────

class LocalMediaService {
  final String      _baseUrl;
  final http.Client _http;

  static const Duration _uploadTimeout = Duration(minutes: 5);

  LocalMediaService({required String baseUrl, http.Client? httpClient})
      : _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _http = httpClient ?? http.Client();

  Future<String?> _getToken() async =>
      FirebaseAuth.instance.currentUser?.getIdToken();

  // ── Core upload ─────────────────────────────────────────────────────────────

  /// Upload [file] vers [endpoint], retourne un [UploadResult].
  ///
  /// Le backend NestJS répond avec :
  /// ```json
  /// {
  ///   "success": true,
  ///   "data": {
  ///     "url":        "https://[tunnel]/media/object/bucket/userId/file.ext",
  ///     "key":        "userId/timestamp_uuid.ext",
  ///     "storedPath": "bucket/userId/timestamp_uuid.ext"
  ///   }
  /// }
  /// ```
  Future<UploadResult> _upload(File file, String endpoint) async {
    if (!await file.exists()) {
      throw CloudinaryServiceException(
        'File does not exist: ${file.path}',
        code: 'FILE_NOT_FOUND',
      );
    }
    final fileSize = await file.length();
    if (fileSize == 0) {
      throw CloudinaryServiceException('File is empty', code: 'EMPTY_FILE');
    }

    final token   = await _getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl$endpoint'),
    );
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    try {
      final streamed = await request.send().timeout(_uploadTimeout);
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        String detail = '';
        try {
          final body = jsonDecode(response.body);
          detail = (body['message'] as String?) ?? '';
        } catch (_) {}
        throw CloudinaryServiceException(
          'Upload failed (${response.statusCode})${detail.isNotEmpty ? ': $detail' : ''}',
          code: 'UPLOAD_FAILED',
        );
      }

      // Parser la réponse — le ResponseInterceptor NestJS enveloppe en
      // { success: true, data: { url, key, storedPath } }
      final decoded = jsonDecode(response.body);
      final Map<String, dynamic> data;

      if (decoded is Map &&
          decoded['success'] == true &&
          decoded.containsKey('data')) {
        data = (decoded['data'] as Map).cast<String, dynamic>();
      } else if (decoded is Map) {
        data = decoded.cast<String, dynamic>();
      } else {
        throw const CloudinaryServiceException(
          'Unexpected response format',
          code: 'PARSE_ERROR',
        );
      }

      final storedPath = data['storedPath'] as String? ?? '';
      final url        = data['url']        as String? ?? storedPath;

      if (storedPath.isEmpty) {
        throw const CloudinaryServiceException(
          'No storedPath in upload response',
          code: 'PARSE_ERROR',
        );
      }

      if (kDebugMode) {
        debugPrint('[LocalMediaService] Upload success: storedPath=$storedPath');
      }

      return UploadResult(url: url, storedPath: storedPath);
    } on CloudinaryServiceException {
      rethrow;
    } catch (e) {
      throw CloudinaryServiceException(
        'Upload error: ${e.toString()}',
        code: 'UPLOAD_ERROR',
        originalError: e,
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // API publique
  // ══════════════════════════════════════════════════════════════════════════

  /// Upload une image (JPEG / PNG / WebP, max 10 MB).
  ///
  /// Retourne un [UploadResult]. Persister [UploadResult.storedPath] en base.
  Future<UploadResult> uploadImage(File file, {String? folder}) =>
      _upload(file, '/media/upload/image');

  /// Upload une vidéo (MP4 / MOV…, max 100 MB).
  ///
  /// Retourne un [UploadResult]. Persister [UploadResult.storedPath] en base.
  Future<UploadResult> uploadVideo(
    File file, {
    String? folder,
    int?    maxDurationSeconds,
  }) =>
      _upload(file, '/media/upload/video');

  /// Upload un fichier audio (M4A / WAV / MP3…, max 50 MB).
  ///
  /// Retourne un [UploadResult]. Persister [UploadResult.storedPath] en base.
  Future<UploadResult> uploadAudio(File file, {String? folder}) =>
      _upload(file, '/media/upload/audio');

  // ── Stubs rétrocompatibles ─────────────────────────────────────────────────
  // Ces méthodes étaient présentes dans l'ancienne CloudinaryService.
  // Conservées pour les call sites qui les utilisent encore.

  /// Construit une URL proxy depuis un storedPath ou une ancienne URL.
  ///
  /// @deprecated Utiliser MediaPathHelper.toUrl() à la place.
  String getOptimizedImageUrl(
    String publicIdOrStoredPath, {
    int?   width,
    int?   height,
    String crop    = 'fill',
    int    quality = 80,
    String format  = 'auto',
  }) =>
      // Les storedPaths sont retournés tels quels — l'appelant doit utiliser
      // MediaPathHelper.toUrl() pour construire l'URL complète.
      publicIdOrStoredPath;

  /// @deprecated Les transformations vidéo ne sont pas supportées côté MinIO.
  String getVideoUrl(
    String publicIdOrStoredPath, {
    int?   width,
    int?   height,
    String format = 'mp4',
  }) =>
      publicIdOrStoredPath;

  /// Suppression gérée côté serveur via DELETE /media/object/*.
  /// Ce stub retourne toujours false — utiliser ApiService.deleteMedia().
  Future<bool> deleteFile(String publicId) async => false;

  void dispose() => _http.close();
}
