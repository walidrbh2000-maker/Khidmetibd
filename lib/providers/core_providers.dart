// lib/providers/core_providers.dart
//
// URL resolution: AppConfig.initialize() runs in main.dart BEFORE runApp().
// By the time ANY provider here reads _kApiBaseUrl, the 3-layer resolution
// (Firebase Remote Config → --dart-define → hardcoded) is already complete.
//
// MIGRATION NOTE:
//   - loginControllerProvider  → removed (email auth deleted)
//   - registerControllerProvider → removed (email auth deleted)
//   + firebaseAuthServiceProvider → new (phone auth service)
//   + authControllerProvider   → see auth_controller.dart (screen-scoped)
//   + onboardingControllerProvider → see onboarding_controller.dart
//   + profileSetupControllerProvider → see profile_setup_controller.dart
//   + professionsProvider → see professions_provider.dart

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import '../services/realtime_service.dart';
import '../services/local_ai_service.dart';
import '../services/local_media_service.dart';
import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import '../services/firebase_auth_service.dart';
import '../services/language_service.dart';
import '../services/notification_push_service.dart';
import '../services/native_channel_service.dart';
import '../services/permission_service.dart';
import '../services/location_service.dart';
import '../services/wilaya_manager.dart';
import '../services/geographic_grid_service.dart';
import '../services/realtime_location_service.dart';
import '../services/media_service.dart';
import '../services/service_request_service.dart';
import '../services/worker_bid_service.dart';
import '../services/smart_search_service.dart';
import '../services/audio_service.dart';
import '../services/notification_service.dart';
import '../services/routing_service.dart';
import '../services/geocoding_service.dart';
import '../services/speech_to_text_service.dart';
import '../models/user_model.dart';
import '../models/worker_model.dart';
import '../models/service_request_enhanced_model.dart';
import '../models/worker_bid_model.dart';
import '../utils/app_config.dart';
export 'auth_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// API Base URL
// ─────────────────────────────────────────────────────────────────────────────

final apiBaseUrlProvider = Provider<String>((ref) {
  final url = AppConfig.apiBaseUrl;
  _logInfo('API base URL = $url (via ${AppConfig.resolvedVia})');
  return url;
});

String get _kApiBaseUrl => AppConfig.apiBaseUrl;

// ════════════════════════════════════════════════════════════════════════════
// LEVEL 0 — INDEPENDENT SERVICES
// ════════════════════════════════════════════════════════════════════════════

final localAiServiceProvider = Provider<LocalAiService>((ref) {
  _logInfo('Initializing LocalAiService → ${_kApiBaseUrl}');
  final service = LocalAiService(baseUrl: _kApiBaseUrl);
  ref.onDispose(service.dispose);
  return service;
});

final realtimeServiceProvider = Provider<RealtimeService>((ref) {
  _logInfo('Initializing RealtimeService → ${_kApiBaseUrl}');
  final service = RealtimeService(baseUrl: _kApiBaseUrl);
  ref.onDispose(service.dispose);
  return service;
});

final apiServiceProvider = Provider<ApiService>((ref) {
  _logInfo('Initializing ApiService → ${_kApiBaseUrl}');
  final realtime = ref.watch(realtimeServiceProvider);
  final service  = ApiService(baseUrl: _kApiBaseUrl, realtime: realtime);
  service.startCacheCleanup();
  ref.onDispose(service.dispose);
  return service;
});

// Backward-compat alias — callers using firestoreServiceProvider still compile.
final firestoreServiceProvider = apiServiceProvider;

final localMediaServiceProvider = Provider<LocalMediaService>((ref) {
  final service = LocalMediaService(baseUrl: _kApiBaseUrl);
  ref.onDispose(service.dispose);
  return service;
});

final nativeChannelServiceProvider = Provider<NativeChannelService>((ref) {
  final service = NativeChannelService();
  ref.onDispose(service.dispose);
  return service;
});

final permissionServiceProvider = Provider<PermissionService>((ref) {
  final service = PermissionService();
  ref.onDispose(service.dispose);
  return service;
});

final locationServiceProvider = Provider<LocationService>((ref) {
  final service = LocationService();
  ref.onDispose(() async { await service.dispose(); });
  return service;
});

final languageServiceProvider = Provider<LanguageService>((ref) {
  final service = LanguageService();
  ref.onDispose(service.dispose);
  return service;
});

final wilayaManagerProvider = Provider<WilayaManager>((ref) {
  final service = WilayaManager();
  ref.onDispose(service.dispose);
  return service;
});

final routingServiceProvider = Provider<RoutingService>((ref) {
  final service = RoutingService();
  ref.onDispose(service.dispose);
  return service;
});

final geocodingServiceProvider = Provider<GeocodingService>((ref) {
  final service = GeocodingService();
  ref.onDispose(service.dispose);
  return service;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService();
  ref.onDispose(service.dispose);
  return service;
});

final audioServiceProvider = Provider<AudioService>((ref) {
  final service = AudioService();
  ref.onDispose(() async { await service.dispose(); });
  return service;
});

final speechToTextServiceProvider = Provider<SpeechToTextService>((ref) {
  final service = SpeechToTextService();
  ref.onDispose(service.dispose);
  return service;
});

final analyticsServiceProvider = Provider<AnalyticsService>((ref) {
  return AnalyticsService();
});

// ── FirebaseAuthService — stateless phone auth wrapper ─────────────────────

final firebaseAuthServiceProvider = Provider<FirebaseAuthService>((ref) {
  _logInfo('Initializing FirebaseAuthService');
  return FirebaseAuthService();
});

// ════════════════════════════════════════════════════════════════════════════
// LEVEL 1
// ════════════════════════════════════════════════════════════════════════════

final mediaServiceProvider = Provider<MediaService>((ref) {
  final localMedia = ref.watch(localMediaServiceProvider);
  final service    = MediaService(localMedia);
  ref.onDispose(() async { await service.dispose(); });
  return service;
});

final geographicGridServiceProvider = Provider<GeographicGridService>((ref) {
  final service = GeographicGridService(
    ref.watch(apiServiceProvider),
    ref.watch(wilayaManagerProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final authServiceProvider = Provider<AuthService>((ref) {
  _logInfo('Initializing AuthService');
  final service = AuthService(ref.watch(apiServiceProvider));
  ref.onDispose(service.dispose);
  return service;
});

// ════════════════════════════════════════════════════════════════════════════
// LEVEL 2
// ════════════════════════════════════════════════════════════════════════════

final notificationPushServiceProvider = Provider<NotificationPushService>((ref) {
  final service = NotificationPushService(
    ref.watch(authServiceProvider),
    ref.watch(apiServiceProvider),
  );
  ref.onDispose(() async { await service.dispose(); });
  return service;
});

final realTimeLocationServiceProvider = Provider<RealTimeLocationService>((ref) {
  final service = RealTimeLocationService(
    ref.watch(authServiceProvider),
    ref.watch(apiServiceProvider),
  );
  ref.onDispose(() async { await service.dispose(); });
  return service;
});

final serviceRequestServiceProvider = Provider<ServiceRequestService>((ref) {
  final service = ServiceRequestService(
    ref.watch(apiServiceProvider),
    ref.watch(mediaServiceProvider),
    ref.watch(geographicGridServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final workerBidServiceProvider = Provider<WorkerBidService>((ref) {
  final service = WorkerBidService(ref.watch(apiServiceProvider));
  ref.onDispose(service.dispose);
  return service;
});

final smartSearchServiceProvider = Provider<SmartSearchService>((ref) {
  final service = SmartSearchService(
    ref.watch(apiServiceProvider),
    ref.watch(geographicGridServiceProvider),
    ref.watch(wilayaManagerProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

// ════════════════════════════════════════════════════════════════════════════
// LANGUAGE — locale state adapter
// ════════════════════════════════════════════════════════════════════════════

class _LocaleStateNotifier extends StateNotifier<Locale> {
  final LanguageService _service;

  _LocaleStateNotifier(this._service) : super(_service.currentLocale) {
    _service.addListener(_onLocaleChanged);
  }

  void _onLocaleChanged() {
    final l = _service.currentLocale;
    if (l != state) state = l;
  }

  @override
  void dispose() {
    _service.removeListener(_onLocaleChanged);
    super.dispose();
  }
}

final localeStateNotifierProvider =
    StateNotifierProvider<_LocaleStateNotifier, Locale>((ref) {
  return _LocaleStateNotifier(ref.watch(languageServiceProvider));
});

final currentLocaleProvider = Provider<Locale>((ref) =>
    ref.watch(localeStateNotifierProvider));

final currentLanguageCodeProvider = Provider<String>((ref) =>
    ref.watch(localeStateNotifierProvider).languageCode);

final isRTLProvider = Provider<bool>((ref) {
  return ref.watch(localeStateNotifierProvider).languageCode == 'ar';
});

final currentLanguageNameProvider = Provider<String>((ref) {
  final locale = ref.watch(localeStateNotifierProvider);
  return ref.read(languageServiceProvider).getLanguageName(locale.languageCode);
});

// ════════════════════════════════════════════════════════════════════════════
// PERMISSIONS
// ════════════════════════════════════════════════════════════════════════════

final hasLocationPermissionProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await ref.watch(permissionServiceProvider).hasLocationPermission();
  } catch (_) { return false; }
});

final hasAllCriticalPermissionsProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await ref.watch(permissionServiceProvider).areAllCriticalPermissionsGranted();
  } catch (_) { return false; }
});

// ════════════════════════════════════════════════════════════════════════════
// PROFILE PROVIDERS
// ════════════════════════════════════════════════════════════════════════════

final userProfileProvider = FutureProvider.family
    .autoDispose<UserModel?, String>((ref, String userId) async {
  if (userId.trim().isEmpty) throw ArgumentError('User ID cannot be empty');
  try {
    return await ref.watch(apiServiceProvider).getUser(userId);
  } catch (e) { rethrow; }
});

final workerProfileProvider = FutureProvider.family
    .autoDispose<WorkerModel?, String>((ref, String workerId) async {
  if (workerId.trim().isEmpty) throw ArgumentError('Worker ID cannot be empty');
  try {
    return await ref.watch(apiServiceProvider).getWorker(workerId);
  } catch (e) { rethrow; }
});

final serviceRequestProvider = FutureProvider.family
    .autoDispose<ServiceRequestEnhancedModel?, String>((ref, String requestId) async {
  if (requestId.trim().isEmpty) throw ArgumentError('Request ID cannot be empty');
  try {
    return await ref.watch(apiServiceProvider).getServiceRequest(requestId);
  } catch (e) { rethrow; }
});

// ════════════════════════════════════════════════════════════════════════════
// STREAM PROVIDERS
// ════════════════════════════════════════════════════════════════════════════

final userServiceRequestsStreamProvider = StreamProvider.family
    .autoDispose<List<ServiceRequestEnhancedModel>, String>((ref, String userId) {
  final api = ref.watch(apiServiceProvider);
  if (userId.trim().isEmpty) return Stream.error(ArgumentError('User ID cannot be empty'));
  return api.streamUserServiceRequests(userId);
});

final workerServiceRequestsStreamProvider = StreamProvider.family
    .autoDispose<List<ServiceRequestEnhancedModel>, String>((ref, String workerId) {
  final api = ref.watch(apiServiceProvider);
  if (workerId.trim().isEmpty) return Stream.error(ArgumentError('Worker ID cannot be empty'));
  return api.streamWorkerServiceRequests(workerId);
});

final serviceRequestStreamProvider = StreamProvider.family
    .autoDispose<ServiceRequestEnhancedModel?, String>((ref, String requestId) {
  final api = ref.watch(apiServiceProvider);
  if (requestId.trim().isEmpty) return Stream.error(ArgumentError('Request ID cannot be empty'));
  return api.streamServiceRequest(requestId);
});

final bidsStreamProvider = StreamProvider.family
    .autoDispose<List<WorkerBidModel>, String>((ref, String requestId) {
  final bidService = ref.watch(workerBidServiceProvider);
  if (requestId.trim().isEmpty) return Stream.error(ArgumentError('Request ID cannot be empty'));
  return bidService.streamBidsForRequest(requestId);
});

final availableRequestsStreamProvider = StreamProvider.family.autoDispose<
    List<ServiceRequestEnhancedModel>,
    ({int wilayaCode, String serviceType})>((ref, params) {
  final bidService = ref.watch(workerBidServiceProvider);
  return bidService.streamAvailableRequests(
      wilayaCode: params.wilayaCode, serviceType: params.serviceType);
});

final workerActiveJobsStreamProvider = StreamProvider.family
    .autoDispose<List<ServiceRequestEnhancedModel>, String>((ref, String workerId) {
  final bidService = ref.watch(workerBidServiceProvider);
  if (workerId.trim().isEmpty) return Stream.error(ArgumentError('Worker ID cannot be empty'));
  return bidService.streamWorkerActiveJobs(workerId);
});

final workerBidsStreamProvider = StreamProvider.family
    .autoDispose<List<WorkerBidModel>, String>((ref, String workerId) {
  final bidService = ref.watch(workerBidServiceProvider);
  if (workerId.trim().isEmpty) return Stream.error(ArgumentError('Worker ID cannot be empty'));
  return bidService.streamWorkerBids(workerId);
});

// ════════════════════════════════════════════════════════════════════════════
// UTILITY
// ════════════════════════════════════════════════════════════════════════════

final servicesInitializedProvider = Provider<bool>((ref) {
  ref.watch(apiServiceProvider);
  ref.watch(authServiceProvider);
  ref.watch(languageServiceProvider);
  return true;
});

// ── Logging ────────────────────────────────────────────────────────────────

void _logInfo(String message) {
  if (kDebugMode) debugPrint('[CoreProviders] $message');
}

// ── Provider observer ──────────────────────────────────────────────────────

class CoreProviderObserver extends ProviderObserver {
  const CoreProviderObserver();

  @override
  void didAddProvider(ProviderBase p, Object? v, ProviderContainer c) {
    if (kDebugMode) debugPrint('[Provider] Added: ${p.name ?? p.runtimeType}');
  }

  @override
  void didDisposeProvider(ProviderBase p, ProviderContainer c) {
    if (kDebugMode) debugPrint('[Provider] Disposed: ${p.name ?? p.runtimeType}');
  }

  @override
  void providerDidFail(ProviderBase p, Object e, StackTrace s, ProviderContainer c) {
    if (kDebugMode) {
      debugPrint('[Provider] FAILED: ${p.name ?? p.runtimeType} → $e');
    }
  }
}
