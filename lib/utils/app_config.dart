// lib/utils/app_config.dart
//
// URL STRATEGY — two layers:
//
//   LAYER 1 — Firebase Remote Config (source of truth, no rebuild needed)
//     Key: "api_base_url"
//     Change it from the Firebase console → app picks it up in ≤ 60 s (next cold start).
//     Dev value  → Cloudflare Tunnel URL (always the same hostname, see Makefile: make tunnel)
//     Prod value → https://api.khidmeti.dz  (or your VPS)
//
//   LAYER 2 — Compile-time fallback (only used if Remote Config unreachable on first launch)
//     flutter run  --dart-define=API_BASE_URL=https://khidmeti-dev.cfargotunnel.com
//     flutter build --dart-define=API_BASE_URL=https://api.khidmeti.dz
//
// WHY NOT HOSTNAME?
//   Android mDNS (.local) requires Multicast DNS support — often blocked on corporate
//   or university WiFi. iOS handles it better, but still unreliable. Fixed tunnel = zero config.
//
// HOW TO CHANGE URL WITHOUT REBUILD:
//   Firebase Console → Remote Config → api_base_url → Publish
//   App fetches on next cold start. Force immediate: kill & relaunch.

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

class AppConfig {
  AppConfig._();

  // ── In-memory resolved URL (set once during initialize()) ─────────────────
  static String _apiBaseUrl = _compileFallback;

  // ── Compile-time fallback (dart-define or hardcoded dev tunnel) ────────────
  // Set this ONCE when you create your Cloudflare Named Tunnel.
  // It never changes even if the machine or WiFi changes.
  static const String _compileFallback = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://khidmeti-dev.cfargotunnel.com', // ← your named tunnel URL
  );

  // ── Public getter used by core_providers.dart ──────────────────────────────
  static String get apiBaseUrl => _apiBaseUrl;

  // ── MapTiler (already here) ────────────────────────────────────────────────
  static String get maptilerApiKey => _getString('maptiler_api_key', 'btE7rXDcH3x6nBHcYTUY');

  // ═══════════════════════════════════════════════════════════════════════════
  // initialize() — called once from main.dart before runApp()
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<void> initialize() async {
    try {
      final rc = FirebaseRemoteConfig.instance;

      // Defaults embedded in the app — used when offline or first launch
      await rc.setDefaults({
        'api_base_url':     _compileFallback,
        'maptiler_api_key': 'btE7rXDcH3x6nBHcYTUY',
      });

      // Fetch + activate in one shot
      // minimumFetchInterval = 0 in debug (instant), 1 h in release
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout:          const Duration(seconds: 8),
        minimumFetchInterval:  kDebugMode
            ? Duration.zero
            : const Duration(hours: 1),
      ));

      await rc.fetchAndActivate();

      // Resolve URL: Remote Config → compile-time fallback
      final remoteUrl = rc.getString('api_base_url').trim();
      _apiBaseUrl = remoteUrl.isNotEmpty ? remoteUrl : _compileFallback;

      if (kDebugMode) {
        debugPrint('[AppConfig] API URL resolved → $_apiBaseUrl');
        debugPrint('[AppConfig] Source: ${remoteUrl.isNotEmpty ? "Remote Config" : "compile-time fallback"}');
      }
    } catch (e) {
      // Remote Config unreachable (no internet at boot, first install, etc.)
      // Fall back to compile-time value — app still works.
      _apiBaseUrl = _compileFallback;
      if (kDebugMode) {
        debugPrint('[AppConfig] Remote Config fetch failed — using fallback: $_apiBaseUrl');
        debugPrint('[AppConfig] Error: $e');
      }
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  static String _getString(String key, String fallback) {
    try {
      final val = FirebaseRemoteConfig.instance.getString(key).trim();
      return val.isNotEmpty ? val : fallback;
    } catch (_) {
      return fallback;
    }
  }
}
