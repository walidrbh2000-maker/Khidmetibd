// lib/services/language_service.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';

class LanguageServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  LanguageServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'LanguageServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class LanguageService extends ChangeNotifier {
  static const Locale defaultLocale = Locale('fr');
  
  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('fr'),
    Locale('ar'),
  ];

  static const String languageCodeEnglish = 'en';
  static const String languageCodeFrench = 'fr';
  static const String languageCodeArabic = 'ar';

  static const Map<String, String> _languageNames = {
    languageCodeEnglish: 'English',
    languageCodeFrench: 'Français',
    languageCodeArabic: 'العربية',
  };

  static const Map<String, String> _languageFlags = {
    languageCodeEnglish: '🇬🇧',
    languageCodeFrench: '🇫🇷',
    languageCodeArabic: '🇩🇿',
  };

  static const Set<String> _rtlLanguages = {languageCodeArabic};

  Locale _currentLocale = defaultLocale;
  bool _isInitialized = false;
  bool _isDisposed = false;

  Locale get currentLocale => _currentLocale;
  bool get isInitialized => _isInitialized;
  bool get isRTL => _rtlLanguages.contains(_currentLocale.languageCode);

  String get currentLanguageName {
    return _languageNames[_currentLocale.languageCode] ?? 
           _languageNames[languageCodeFrench]!;
  }

  String get currentLanguageFlag {
    return _languageFlags[_currentLocale.languageCode] ?? 
           _languageFlags[languageCodeFrench]!;
  }

  Future<void> initialize() async {
    if (_isInitialized) {
      _logWarning('LanguageService already initialized');
      return;
    }

    _ensureNotDisposed();

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedLanguageCode = prefs.getString(PrefKeys.languageCode);

      if (savedLanguageCode != null && savedLanguageCode.isNotEmpty) {
        final locale = Locale(savedLanguageCode);
        
        if (_isSupportedLocale(locale)) {
          _currentLocale = locale;
          _logInfo('Loaded saved language: $savedLanguageCode');
        } else {
          _logWarning('Unsupported saved language: $savedLanguageCode, using default');
          await _saveLanguageToPreferences(defaultLocale.languageCode);
        }
      } else {
        _logInfo('No saved language, using default: ${defaultLocale.languageCode}');
        await _saveLanguageToPreferences(defaultLocale.languageCode);
      }

      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      _logError('initialize', e);
      _currentLocale = defaultLocale;
      _isInitialized = true;
      notifyListeners();
    }
  }

  Future<void> changeLanguage(String languageCode) async {
    _ensureNotDisposed();

    if (languageCode.trim().isEmpty) {
      throw LanguageServiceException(
        'Language code cannot be empty',
        code: 'INVALID_LANGUAGE_CODE',
      );
    }

    final normalizedLanguageCode = languageCode.trim().toLowerCase();
    final newLocale = Locale(normalizedLanguageCode);

    if (!_isSupportedLocale(newLocale)) {
      throw LanguageServiceException(
        'Unsupported language: $normalizedLanguageCode',
        code: 'UNSUPPORTED_LANGUAGE',
      );
    }

    if (_currentLocale.languageCode == normalizedLanguageCode) {
      _logInfo('Language already set to: $normalizedLanguageCode');
      return;
    }

    try {
      _currentLocale = newLocale;
      notifyListeners();

      await _saveLanguageToPreferences(normalizedLanguageCode);

      _logInfo('Language changed to: $normalizedLanguageCode');
    } catch (e) {
      _logError('changeLanguage', e);
      
      if (e is LanguageServiceException) rethrow;
      throw LanguageServiceException(
        'Failed to change language',
        code: 'CHANGE_LANGUAGE_FAILED',
        originalError: e,
      );
    }
  }

  Future<void> changeToEnglish() async {
    await changeLanguage(languageCodeEnglish);
  }

  Future<void> changeToFrench() async {
    await changeLanguage(languageCodeFrench);
  }

  Future<void> changeToArabic() async {
    await changeLanguage(languageCodeArabic);
  }

  String getLanguageName(String languageCode) {
    return _languageNames[languageCode] ?? languageCode;
  }

  String getLanguageFlag(String languageCode) {
    return _languageFlags[languageCode] ?? '';
  }

  bool isLanguageSupported(String languageCode) {
    return _isSupportedLocale(Locale(languageCode));
  }

  bool _isSupportedLocale(Locale locale) {
    return supportedLocales.any(
      (l) => l.languageCode == locale.languageCode,
    );
  }

  Future<void> _saveLanguageToPreferences(String languageCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setString(PrefKeys.languageCode, languageCode);
      
      if (!saved) {
        _logWarning('Failed to save language preference');
      }
    } catch (e) {
      _logError('_saveLanguageToPreferences', e);
      throw LanguageServiceException(
        'Failed to save language preference',
        code: 'SAVE_PREFERENCE_FAILED',
        originalError: e,
      );
    }
  }

  Future<void> resetToDefault() async {
    _ensureNotDisposed();

    try {
      await changeLanguage(defaultLocale.languageCode);
      _logInfo('Language reset to default');
    } catch (e) {
      _logError('resetToDefault', e);
      throw LanguageServiceException(
        'Failed to reset language',
        code: 'RESET_FAILED',
        originalError: e,
      );
    }
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw LanguageServiceException(
        'LanguageService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    debugPrint('[LanguageService] INFO: $message');
  }

  void _logWarning(String message) {
    debugPrint('[LanguageService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    debugPrint('[LanguageService] ERROR in $method: $error');
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    
    _isDisposed = true;
    _logInfo('LanguageService disposed');
    super.dispose();
  }
}