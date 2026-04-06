// lib/providers/theme_provider.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';

// ============================================================================
// THEME MODE NOTIFIER
// ============================================================================

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _loadSavedTheme();
  }

  Future<void> _loadSavedTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(PrefKeys.themeMode);
      state = _fromString(saved);
      AppLogger.info('ThemeMode loaded: $state');
    } catch (e) {
      AppLogger.error('ThemeModeNotifier._loadSavedTheme', e);
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    try {
      state = mode;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PrefKeys.themeMode, _toString(mode));
      AppLogger.info('ThemeMode saved: $mode');
    } catch (e) {
      AppLogger.error('ThemeModeNotifier.setThemeMode', e);
    }
  }

  ThemeMode _fromString(String? value) {
    switch (value) {
      case 'light':  return ThemeMode.light;
      case 'dark':   return ThemeMode.dark;
      default:       return ThemeMode.system;
    }
  }

  String _toString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:  return 'light';
      case ThemeMode.dark:   return 'dark';
      case ThemeMode.system: return 'system';
    }
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});
