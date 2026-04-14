// lib/utils/media_path_helper.dart
//
// ARCHITECTURE — storedPath vs URL
//
// PROBLÈME RÉSOLU :
//   Les URLs complètes stockées en base (http://minio:9001/... ou presigned URLs)
//   devenaient invalides dès que le domaine Cloudflare changeait ou que le
//   réseau local changeait.
//
// SOLUTION :
//   • En base : on stocke uniquement le "storedPath" = "bucket/userId/file.ext"
//     Exemple : "service-media/abc123/1715000000_550e8400.jpg"
//   • À l'affichage : on construit l'URL proxy dynamiquement :
//     MediaPathHelper.toUrl(storedPath, apiBaseUrl: AppConfig.apiBaseUrl)
//     → "https://[cloudflare-actuel].com/media/object/service-media/abc123/..."
//
// MIGRATION AUTOMATIQUE :
//   toUrl() normalise aussi les anciennes URLs (presigned, http://minio:9001,
//   http://localhost:9001, etc.) sans aucun changement de code appelant.
//   Il suffit de passer l'ancienne valeur — elle sera redirigée vers le proxy.
//
// USAGE TYPIQUE :
//   ```dart
//   // Affichage d'une image
//   final displayUrl = MediaPathHelper.toUrl(
//     request.mediaUrls.first,          // storedPath OU ancienne URL
//     apiBaseUrl: RemoteConfig.apiUrl,   // URL courante du tunnel Cloudflare
//   );
//   Image.network(displayUrl)
//
//   // Stockage après upload
//   final result = await mediaService.uploadImage(file);
//   request.mediaUrls.add(result.storedPath);   // ← persister storedPath
//
//   // Vérifier si une valeur est déjà un storedPath
//   if (MediaPathHelper.isStoredPath(value)) { ... }
//   ```

import 'package:flutter/foundation.dart';

class MediaPathHelper {
  // ── Construction ────────────────────────────────────────────────────────────
  // Classe utilitaire pure — constructeur privé, que des méthodes statiques.
  MediaPathHelper._();

  /// Segment de chemin identifiant les routes proxy NestJS.
  static const String _proxySegment = '/media/object/';

  // ══════════════════════════════════════════════════════════════════════════
  // toUrl() — conversion principale
  // ══════════════════════════════════════════════════════════════════════════

  /// Convertit n'importe quelle référence média en URL d'affichage complète.
  ///
  /// [storedPathOrUrl] peut être :
  ///   • Stored path :   "service-media/userId/file.jpg"           ← cas normal
  ///   • Proxy URL :     "https://old-tunnel.com/media/object/..." ← re-rooté
  ///   • URL MinIO :     "http://minio:9001/bucket/key"            ← migré
  ///   • Presigned URL : "http://192.168.x.x:9001/bucket/key?X-Amz-..." ← migré
  ///   • null ou vide :  retourne ""
  ///
  /// [apiBaseUrl] : URL courante de l'API, ex. "https://xyz.trycloudflare.com"
  ///
  /// La fonction est pure et idempotente : appeler toUrl sur un résultat de
  /// toUrl produit le même résultat (avec le même apiBaseUrl).
  static String toUrl(
    String? storedPathOrUrl, {
    required String apiBaseUrl,
  }) {
    if (storedPathOrUrl == null || storedPathOrUrl.isEmpty) return '';

    // Normaliser le baseUrl : supprimer le slash final
    final base = apiBaseUrl.endsWith('/')
        ? apiBaseUrl.substring(0, apiBaseUrl.length - 1)
        : apiBaseUrl;

    // ── Cas 1 : déjà une URL proxy NestJS (/media/object/…) ──────────────────
    // Re-roote vers le apiBaseUrl courant pour gérer les changements de domaine.
    // Ex: "https://ancien-tunnel.com/media/object/bucket/key"
    //   → "https://nouveau-tunnel.com/media/object/bucket/key"
    if (storedPathOrUrl.contains(_proxySegment)) {
      final idx  = storedPathOrUrl.indexOf(_proxySegment);
      final path = storedPathOrUrl.substring(idx + _proxySegment.length);
      // Supprimer les query params éventuels (ex: presigned params hérités)
      final cleanPath = path.split('?').first;
      if (cleanPath.isEmpty) return '';
      return '$base$_proxySegment$cleanPath';
    }

    // ── Cas 2 : URL HTTP complète (MinIO direct, presigned, ou tout host) ────
    // Extrait le "bucket/key" du path URI et redirige vers le proxy.
    if (storedPathOrUrl.startsWith('http')) {
      try {
        final uri = Uri.parse(storedPathOrUrl);
        // uri.path = "/bucket/userId/file.jpg" → supprimer le '/' initial
        final rawPath = uri.path.startsWith('/')
            ? uri.path.substring(1)
            : uri.path;
        if (rawPath.isEmpty) return storedPathOrUrl;

        if (kDebugMode) {
          debugPrint(
            '[MediaPathHelper] Migration URL legacy → proxy:\n'
            '  AVANT : $storedPathOrUrl\n'
            '  APRÈS : $base$_proxySegment$rawPath',
          );
        }
        return '$base$_proxySegment$rawPath';
      } catch (_) {
        // URL non parseable — retourner tel quel pour éviter toute perte de données
        return storedPathOrUrl;
      }
    }

    // ── Cas 3 : storedPath propre "bucket/key" ────────────────────────────────
    return '$base$_proxySegment$storedPathOrUrl';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // toStoredPath() — extraction du chemin durable
  // ══════════════════════════════════════════════════════════════════════════

  /// Extrait le storedPath ("bucket/key") depuis n'importe quelle forme d'URL.
  ///
  /// Utile pour normaliser des valeurs héritées avant de les enregistrer en base.
  ///
  /// Exemples :
  ///   "https://tunnel.com/media/object/service-media/u/f.jpg" → "service-media/u/f.jpg"
  ///   "http://minio:9001/service-media/u/f.jpg"               → "service-media/u/f.jpg"
  ///   "service-media/u/f.jpg"                                 → "service-media/u/f.jpg"
  static String toStoredPath(String urlOrPath) {
    if (urlOrPath.isEmpty) return urlOrPath;

    // Depuis une URL proxy NestJS
    if (urlOrPath.contains(_proxySegment)) {
      final idx = urlOrPath.indexOf(_proxySegment);
      return urlOrPath
          .substring(idx + _proxySegment.length)
          .split('?')
          .first;
    }

    // Depuis une URL HTTP (MinIO direct ou presigned)
    if (urlOrPath.startsWith('http')) {
      try {
        final uri  = Uri.parse(urlOrPath);
        final path = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
        return path;
      } catch (_) {}
    }

    // Déjà un storedPath propre
    return urlOrPath;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Helpers utilitaires
  // ══════════════════════════════════════════════════════════════════════════

  /// Retourne true si [value] est déjà un storedPath durable (pas un URL HTTP).
  ///
  /// Un storedPath ne commence pas par "http" et ne commence pas par "/".
  /// Ex: "service-media/userId/file.jpg" → true
  ///     "https://tunnel.com/media/..." → false
  static bool isStoredPath(String value) =>
      value.isNotEmpty &&
      !value.startsWith('http') &&
      !value.startsWith('/');

  /// Retourne true si [value] est une ancienne URL interne MinIO.
  ///
  /// Utilisé pour détecter les données héritées à migrer.
  static bool isLegacyMinioUrl(String value) =>
      value.contains(':9001') ||
      value.contains('minio:') ||
      (value.startsWith('http') && !value.contains(_proxySegment));

  /// Convertit une liste de références média (storedPaths ou anciennes URLs).
  ///
  /// Pratique pour les champs mediaUrls des ServiceRequest.
  static List<String> listToUrls(
    List<String> items, {
    required String apiBaseUrl,
  }) =>
      items
          .map((item) => toUrl(item, apiBaseUrl: apiBaseUrl))
          .where((url) => url.isNotEmpty)
          .toList();
}
