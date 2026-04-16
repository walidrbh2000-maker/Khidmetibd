// lib/providers/professions_provider.dart
//
// Cached profession list from the backend /professions endpoint.
//
// Architecture:
//   1. Check SharedPreferences cache (TTL 24h).
//   2. If cache miss or stale → GET /professions?lang=<current>.
//   3. If network fails → fall back to kDefaultProfessions (always available).
//
// The profession list changes rarely (new professions added every few weeks).
// 24h TTL means users see new professions without restart, but we don't
// hammer the API on every launch.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/profession_model.dart';
import '../services/api_service.dart';
import 'core_providers.dart';

// ── Cache keys ─────────────────────────────────────────────────────────────

const _kCacheKey   = 'professions_cache_v1';
const _kCacheTsKey = 'professions_cache_ts_v1';
const _kCacheTTL   = Duration(hours: 24);

// ─────────────────────────────────────────────────────────────────────────────
// ProfessionsNotifier — manages fetching + caching
// ─────────────────────────────────────────────────────────────────────────────

class ProfessionsNotifier extends AsyncNotifier<List<ProfessionModel>> {
  String _lang = 'fr';

  @override
  Future<List<ProfessionModel>> build() async {
    _lang = ref.watch(currentLanguageCodeProvider);
    return _load();
  }

  Future<List<ProfessionModel>> _load() async {
    // 1. Try shared prefs cache
    final cached = await _loadFromCache();
    if (cached != null) return cached;

    // 2. Fetch from API
    try {
      final professions = await ref.read(apiServiceProvider).getProfessions(lang: _lang);
      if (professions.isNotEmpty) {
        await _saveToCache(professions);
        return professions;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[ProfessionsNotifier] API fetch failed: $e');
    }

    // 3. Offline fallback
    _log('Using offline fallback — ${kDefaultProfessions.length} professions');
    return kDefaultProfessions;
  }

  /// Force-refresh from network (pull-to-refresh or after adding a new profession).
  Future<void> refresh() async {
    await _invalidateCache();
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _load());
  }

  // ── Cache helpers ──────────────────────────────────────────────────────────

  Future<List<ProfessionModel>?> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts    = prefs.getInt(_kCacheTsKey);
      if (ts == null) return null;

      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age > _kCacheTTL.inMilliseconds) return null;

      final raw = prefs.getString(_kCacheKey);
      if (raw == null) return null;

      final list = (jsonDecode(raw) as List)
          .map((e) => ProfessionModel.fromJson(e as Map<String, dynamic>, lang: _lang))
          .toList();

      _log('Loaded ${list.length} professions from cache');
      return list;
    } catch (e) {
      if (kDebugMode) debugPrint('[ProfessionsNotifier] Cache read error: $e');
      return null;
    }
  }

  Future<void> _saveToCache(List<ProfessionModel> professions) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = jsonEncode(professions.map((p) => p.toJson()).toList());
      await prefs.setString(_kCacheKey, raw);
      await prefs.setInt(_kCacheTsKey, DateTime.now().millisecondsSinceEpoch);
      _log('Cached ${professions.length} professions');
    } catch (e) {
      if (kDebugMode) debugPrint('[ProfessionsNotifier] Cache write error: $e');
    }
  }

  Future<void> _invalidateCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kCacheKey);
      await prefs.remove(_kCacheTsKey);
    } catch (_) {}
  }

  void _log(String msg) { if (kDebugMode) debugPrint('[ProfessionsNotifier] $msg'); }
}

// ─────────────────────────────────────────────────────────────────────────────
// Providers
// ─────────────────────────────────────────────────────────────────────────────

/// All active professions in the current locale, sorted by sortOrder.
final professionsProvider =
    AsyncNotifierProvider<ProfessionsNotifier, List<ProfessionModel>>(
  ProfessionsNotifier.new,
);

/// Professions grouped by category — for the category-aware picker view.
final professionsByCategoryProvider =
    Provider<Map<String, List<ProfessionModel>>>((ref) {
  final asyncProfessions = ref.watch(professionsProvider);
  final professions      = asyncProfessions.valueOrNull ?? kDefaultProfessions;

  final Map<String, List<ProfessionModel>> grouped = {};
  for (final p in professions) {
    (grouped[p.categoryKey] ??= []).add(p);
  }
  return grouped;
});

/// Finds a ProfessionModel by key — returns null if not found.
/// Used by the voice detection flow to resolve a key to a display label.
final professionByKeyProvider =
    Provider.family<ProfessionModel?, String>((ref, key) {
  final asyncProfessions = ref.watch(professionsProvider);
  final professions      = asyncProfessions.valueOrNull ?? kDefaultProfessions;
  try {
    return professions.firstWhere((p) => p.key == key);
  } catch (_) {
    return null;
  }
});
