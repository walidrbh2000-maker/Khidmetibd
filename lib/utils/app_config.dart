// lib/utils/app_config.dart
//
// MIGRATION STEP 6 — SIMPLIFIED
//
// AVANT : fetchait gemini_api_key + cloudinary_* depuis Firebase Remote Config
//         → ces clés vivaient côté client Flutter (risque sécurité)
//
// APRÈS : toutes les clés IA (Gemini, Ollama, vLLM) sont dans .env SERVER SIDE
//         Flutter n'a besoin que de :
//           • maptiler_api_key  → cartes OpenStreetMap/MapTiler dans l'app
//         Les clés Cloudinary sont supprimées (remplacées par MinIO server-side)
//
// Firebase Remote Config garde UNIQUEMENT maptiler_api_key
// (optionnel : si vous préférez, mettez la clé directement ici en dur)

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

class AppConfig {
  AppConfig._();

  // ── Remote Config — SEULE clé encore utile côté Flutter ──────────────────
  static const String _kMaptiler = 'maptiler_api_key';

  static const Duration _fetchInterval = Duration(hours: 1);

  static FirebaseRemoteConfig get _rc => FirebaseRemoteConfig.instance;

  /// Initialise Firebase Remote Config.
  /// Appelé une seule fois dans main() après Firebase.initializeApp().
  static Future<void> initialize() async {
    try {
      await _rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout:         const Duration(seconds: 10),
        minimumFetchInterval: _fetchInterval,
      ));

      // Valeur par défaut = clé déjà visible dans vos screenshots Remote Config
      await _rc.setDefaults(const {
        _kMaptiler: 'btE7rXDcH3x6nBHcYTUY',
      });

      await _rc.fetchAndActivate();
      _logInfo('AppConfig: Remote Config initialisé');
    } catch (e) {
      // Non-fatal — la valeur par défaut ci-dessus sera utilisée
      _logWarning('AppConfig: Remote Config indisponible — $e');
    }
  }

  /// Clé MapTiler pour les tuiles de carte dans Flutter.
  /// Lue depuis Remote Config (permet de la changer sans redéployer l'app).
  static String get maptilerApiKey {
    final key = _rc.getString(_kMaptiler);
    if (key.isEmpty) _logWarning('AppConfig: maptiler_api_key est vide');
    return key;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SUPPRIMÉ (était côté client, maintenant SERVER SIDE dans .env) :
  //   static String get geminiApiKey  → dans GEMINI_API_KEY (.env)
  //   static String get cloudinaryCloudName   → SUPPRIMÉ (MinIO)
  //   static String get cloudinaryUploadPreset → SUPPRIMÉ (MinIO)
  // ═══════════════════════════════════════════════════════════════════════════

  static void _logInfo(String msg) {
    if (kDebugMode) debugPrint('[AppConfig] $msg');
  }

  static void _logWarning(String msg) {
    if (kDebugMode) debugPrint('[AppConfig] WARNING: $msg');
  }
}
