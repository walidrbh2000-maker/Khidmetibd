// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers/core_providers.dart';
import 'providers/app_lifecycle_provider.dart';
import 'providers/theme_provider.dart';
import 'services/language_service.dart';
import 'router/app_router.dart';
import 'utils/app_config.dart';
import 'utils/app_theme.dart';
import 'utils/localization.dart';
import 'utils/logger.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  AppLogger.info('Background message received: ${message.messageId}');
}

void main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  try {
    AppLogger.info('Initializing Firebase...');
    await Firebase.initializeApp();
    AppLogger.success('Firebase initialized');

    // FIX: Enable Firestore offline persistence explicitly.
    // On Android this is already enabled by default; on iOS it is disabled
    // by default, meaning iOS users get no offline capability without this.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
    );
    AppLogger.info('Firestore offline persistence enabled');

    await AppConfig.initialize();
    AppLogger.success('Remote Config initialized');

    // One-time migration: remove deprecated PrefKeys.viewMode key.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('viewMode');

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor:        Colors.transparent,
        systemNavigationBarDividerColor:      Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        statusBarColor:                  Colors.transparent,
      ),
    );

    runApp(const ProviderScope(child: KhidmetiApp()));
  } catch (e, stackTrace) {
    AppLogger.error('Critical initialization error', e, stackTrace);
    FlutterNativeSplash.remove();
    runApp(_buildErrorApp(e));
  }
}

Widget _buildErrorApp(dynamic error) {
  return MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.red.shade50,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 64),
              const SizedBox(height: 24),
              const Text(
                'Initialization Error',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.red),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red),
                ),
                child: Text('$error', textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class KhidmetiApp extends ConsumerStatefulWidget {
  const KhidmetiApp({super.key});

  @override
  ConsumerState<KhidmetiApp> createState() => _KhidmetiAppState();
}

class _KhidmetiAppState extends ConsumerState<KhidmetiApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    try {
      final languageService = ref.read(languageServiceProvider);
      await languageService.initialize();
      AppLogger.success('Language service initialized');
    } catch (e) {
      AppLogger.error('Service initialization error', e);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    ref.read(appLifecycleProvider.notifier).updateState(state);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(goRouterProvider);
    // FIX (P1): Watch currentLocaleProvider (driven by localeStateNotifierProvider)
    // instead of languageServiceProvider directly. Previously, watching
    // languageServiceProvider subscribed to its ChangeNotifier, which only fired
    // on the very first initialization call — leaving the locale frozen for all
    // subsequent language changes. currentLocaleProvider rebuilds whenever the
    // locale value itself changes, ensuring the app re-renders with the new locale.
    final currentLocale = ref.watch(currentLocaleProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'Khidmeti',
      routerConfig: router,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      locale: currentLocale,
      supportedLocales: LanguageService.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
    );
  }
}
