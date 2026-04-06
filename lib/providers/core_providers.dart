// lib/providers/core_providers.dart
//
// TASK 1 FIX — AuthService and LanguageService provider type migration.
//
// WHAT CHANGED:
//
// 1. authServiceProvider: ChangeNotifierProvider<AuthService> → Provider<AuthService>
//    AuthService is now a plain singleton. Reactive auth state is driven by
//    firebaseAuthStreamProvider in auth_providers.dart (stream from Firebase),
//    not by AuthService's notifyListeners() cycle.
//    All existing ref.watch(authServiceProvider) call sites that only need the
//    service object for method calls continue to work — a plain Provider returns
//    the stable singleton, no behavioural change except no spurious rebuilds.
//
// 2. languageServiceProvider: ChangeNotifierProvider<LanguageService> → Provider<LanguageService>
//    LanguageService is now a plain singleton.
//    Reactive locale state is driven by localeStateNotifierProvider (_LocaleStateNotifier
//    adapter below), which listens to LanguageService's ChangeNotifier
//    and exposes a typed Locale state via StateNotifierProvider. Only locale
//    changes fire Riverpod rebuilds — not unrelated notifyListeners() calls.
//
// 3. currentLocaleProvider / currentLanguageCodeProvider / isRTLProvider:
//    now watch localeStateNotifierProvider instead of languageServiceProvider.
//
// 4. currentLanguageNameProvider (new): exposes the display name for the
//    current locale. Rebuilds when locale changes via localeStateNotifierProvider.
//
// 5. Removed unused imports: cloud_firestore, firebase_auth (both are now only
//    imported by the files that actually use their types).
//
// 6. hasLocationPermissionProvider / hasAllCriticalPermissionsProvider:
//    already migrated to .autoDispose in previous /state-apply session.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

import '../config/cloudinary_config.dart';
import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../services/language_service.dart';
import '../services/notification_push_service.dart';
import '../services/native_channel_service.dart';
import '../services/permission_service.dart';
import '../services/location_service.dart';
import '../services/wilaya_manager.dart';
import '../services/geographic_grid_service.dart';
import '../services/realtime_location_service.dart';
import '../services/media_service.dart';
import '../services/cloudinary_service.dart';
import '../services/service_request_service.dart';
import '../services/worker_bid_service.dart';
import '../services/smart_search_service.dart';
import '../services/ai_intent_extractor.dart';
import '../services/audio_service.dart';
import '../services/notification_service.dart';
import '../services/routing_service.dart';
import '../services/geocoding_service.dart';
import '../services/speech_to_text_service.dart';
import '../models/user_model.dart';
import '../models/worker_model.dart';
import '../models/service_request_enhanced_model.dart';
import '../models/worker_bid_model.dart';
export 'auth_providers.dart';

// ============================================================================
// AI INTENT EXTRACTOR
// ============================================================================

final aiIntentExtractorProvider = Provider<AiIntentExtractorService>((ref) {
  return AiIntentExtractorService();
});

// ============================================================================
// LEVEL 0 — INDEPENDENT SERVICES
// ============================================================================

final firestoreServiceProvider = Provider<FirestoreService>((ref) {
  _logInfo('Initializing FirestoreService');
  final service = FirestoreService();
  service.startCacheCleanup();
  ref.onDispose(() { _logInfo('Disposing FirestoreService'); service.dispose(); });
  return service;
});

final nativeChannelServiceProvider = Provider<NativeChannelService>((ref) {
  _logInfo('Initializing NativeChannelService');
  final service = NativeChannelService();
  ref.onDispose(() { _logInfo('Disposing NativeChannelService'); service.dispose(); });
  return service;
});

final permissionServiceProvider = Provider<PermissionService>((ref) {
  _logInfo('Initializing PermissionService');
  final service = PermissionService();
  ref.onDispose(() { _logInfo('Disposing PermissionService'); service.dispose(); });
  return service;
});

final locationServiceProvider = Provider<LocationService>((ref) {
  _logInfo('Initializing LocationService');
  final service = LocationService();
  ref.onDispose(() async { _logInfo('Disposing LocationService'); await service.dispose(); });
  return service;
});

// FIX (Task 1): ChangeNotifierProvider → Provider<LanguageService>.
// LanguageService is now a plain singleton. Reactive locale state is driven
// by localeStateNotifierProvider below, which adapts the ChangeNotifier into
// a typed Riverpod StateNotifier — firing only on real locale changes.
final languageServiceProvider = Provider<LanguageService>((ref) {
  _logInfo('Initializing LanguageService');
  final service = LanguageService();
  ref.onDispose(() { _logInfo('Disposing LanguageService'); service.dispose(); });
  return service;
});

final wilayaManagerProvider = Provider<WilayaManager>((ref) {
  _logInfo('Initializing WilayaManager');
  final service = WilayaManager();
  ref.onDispose(() { _logInfo('Disposing WilayaManager'); service.dispose(); });
  return service;
});

final cloudinaryServiceProvider = Provider<CloudinaryService>((ref) {
  _logInfo('Initializing CloudinaryService');
  CloudinaryConfig.validate();
  return CloudinaryService(
    cloudName:    CloudinaryConfig.cloudName,
    uploadPreset: CloudinaryConfig.uploadPreset,
  );
});

final routingServiceProvider = Provider<RoutingService>((ref) {
  _logInfo('Initializing RoutingService');
  final service = RoutingService();
  ref.onDispose(() { _logInfo('Disposing RoutingService'); service.dispose(); });
  return service;
});

final geocodingServiceProvider = Provider<GeocodingService>((ref) {
  _logInfo('Initializing GeocodingService');
  final service = GeocodingService();
  ref.onDispose(() { _logInfo('Disposing GeocodingService'); service.dispose(); });
  return service;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  _logInfo('Initializing NotificationService');
  final service = NotificationService();
  ref.onDispose(() { _logInfo('Disposing NotificationService'); service.dispose(); });
  return service;
});

final audioServiceProvider = Provider<AudioService>((ref) {
  _logInfo('Initializing AudioService');
  final service = AudioService();
  ref.onDispose(() async { _logInfo('Disposing AudioService'); await service.dispose(); });
  return service;
});

final speechToTextServiceProvider = Provider<SpeechToTextService>((ref) {
  _logInfo('Initializing SpeechToTextService');
  final service = SpeechToTextService();
  ref.onDispose(() { _logInfo('Disposing SpeechToTextService'); service.dispose(); });
  return service;
});

final analyticsServiceProvider = Provider<AnalyticsService>((ref) {
  _logInfo('Initializing AnalyticsService');
  return AnalyticsService();
});

// ============================================================================
// LEVEL 1
// ============================================================================

final mediaServiceProvider = Provider<MediaService>((ref) {
  _logInfo('Initializing MediaService');
  final cloudinaryService = ref.watch(cloudinaryServiceProvider);
  final service = MediaService(cloudinaryService);
  ref.onDispose(() async { _logInfo('Disposing MediaService'); await service.dispose(); });
  return service;
});

final geographicGridServiceProvider = Provider<GeographicGridService>((ref) {
  _logInfo('Initializing GeographicGridService');
  final service = GeographicGridService(
    ref.watch(firestoreServiceProvider),
    ref.watch(wilayaManagerProvider),
  );
  ref.onDispose(() { _logInfo('Disposing GeographicGridService'); service.dispose(); });
  return service;
});

// FIX (Task 1): ChangeNotifierProvider<AuthService> → Provider<AuthService>.
// AuthService is now a plain singleton used only for method calls (signIn,
// signUp, signOut, etc.). Reactive auth state is driven by
// firebaseAuthStreamProvider in auth_providers.dart, which listens directly to
// Firebase's authStateChanges() stream — eliminating all spurious Riverpod
// rebuilds caused by AuthService's internal isLoading flip cycle.
//
// All existing ref.watch(authServiceProvider) and ref.read(authServiceProvider)
// call sites continue to work unchanged. The difference: ref.watch no longer
// subscribes to ChangeNotifier notifications, so providers that injected
// AuthService (notificationPushService, realTimeLocationService) no longer
// rebuild on every signIn/signOut step.
final authServiceProvider = Provider<AuthService>((ref) {
  _logInfo('Initializing AuthService');
  final service = AuthService(ref.watch(firestoreServiceProvider));
  ref.onDispose(() { _logInfo('Disposing AuthService'); service.dispose(); });
  return service;
});

// ============================================================================
// LEVEL 2
// ============================================================================

final notificationPushServiceProvider = Provider<NotificationPushService>((ref) {
  _logInfo('Initializing NotificationPushService');
  final service = NotificationPushService(
    ref.watch(authServiceProvider),
    ref.watch(firestoreServiceProvider),
  );
  ref.onDispose(() async { _logInfo('Disposing NotificationPushService'); await service.dispose(); });
  return service;
});

final realTimeLocationServiceProvider = Provider<RealTimeLocationService>((ref) {
  _logInfo('Initializing RealTimeLocationService');
  final service = RealTimeLocationService(
    ref.watch(authServiceProvider),
    ref.watch(firestoreServiceProvider),
  );
  ref.onDispose(() async { _logInfo('Disposing RealTimeLocationService'); await service.dispose(); });
  return service;
});

final serviceRequestServiceProvider = Provider<ServiceRequestService>((ref) {
  _logInfo('Initializing ServiceRequestService');
  final service = ServiceRequestService(
    ref.watch(firestoreServiceProvider),
    ref.watch(mediaServiceProvider),
    ref.watch(geographicGridServiceProvider),
  );
  ref.onDispose(() { _logInfo('Disposing ServiceRequestService'); service.dispose(); });
  return service;
});

final workerBidServiceProvider = Provider<WorkerBidService>((ref) {
  _logInfo('Initializing WorkerBidService');
  final service = WorkerBidService(ref.watch(firestoreServiceProvider));
  ref.onDispose(() { _logInfo('Disposing WorkerBidService'); service.dispose(); });
  return service;
});

final smartSearchServiceProvider = Provider<SmartSearchService>((ref) {
  _logInfo('Initializing SmartSearchService');
  final service = SmartSearchService(
    ref.watch(firestoreServiceProvider),
    ref.watch(geographicGridServiceProvider),
    ref.watch(wilayaManagerProvider),
  );
  ref.onDispose(() { _logInfo('Disposing SmartSearchService'); service.dispose(); });
  return service;
});

// ============================================================================
// LANGUAGE — LOCALE STATE ADAPTER (Task 1)
// ============================================================================
//
// _LocaleStateNotifier bridges LanguageService (ChangeNotifier) and Riverpod.
// It adds itself as a listener to LanguageService and propagates locale changes
// into a typed StateNotifier<Locale>. This means:
//   • Only actual locale changes cause Riverpod rebuilds.
//   • LanguageService's other ChangeNotifier callbacks (e.g. initialization)
//     are absorbed correctly because the state only changes when the locale value
//     itself differs from the previous one (StateNotifier's equality check).
//
// Consumers that previously watched languageServiceProvider for display of the
// current locale name should now watch currentLocaleProvider or
// currentLanguageNameProvider instead. For method calls (changeToFrench(), etc.),
// use ref.read(languageServiceProvider).

class _LocaleStateNotifier extends StateNotifier<Locale> {
  final LanguageService _service;

  _LocaleStateNotifier(this._service) : super(_service.currentLocale) {
    _service.addListener(_onLocaleChanged);
  }

  void _onLocaleChanged() {
    // Only update if the locale value actually changed — StateNotifier's
    // equality check prevents spurious downstream rebuilds.
    final newLocale = _service.currentLocale;
    if (newLocale != state) state = newLocale;
  }

  @override
  void dispose() {
    _service.removeListener(_onLocaleChanged);
    super.dispose();
  }
}

/// Reactive locale state — the single source of truth for the app's locale.
/// Rebuilds only when the locale changes, not on unrelated LanguageService
/// notifications.
final localeStateNotifierProvider =
    StateNotifierProvider<_LocaleStateNotifier, Locale>((ref) {
  return _LocaleStateNotifier(ref.watch(languageServiceProvider));
});

// ============================================================================
// LANGUAGE & LOCALE — DERIVED PROVIDERS
// ============================================================================

// FIX (Task 1): These providers now watch localeStateNotifierProvider instead
// of languageServiceProvider. Previously they subscribed to the ChangeNotifier
// directly, which rebuilt them on any notifyListeners() call from LanguageService.
// Now they only rebuild when the locale value itself changes.

final currentLocaleProvider = Provider<Locale>((ref) =>
    ref.watch(localeStateNotifierProvider));

final currentLanguageCodeProvider = Provider<String>((ref) =>
    ref.watch(localeStateNotifierProvider).languageCode);

final isRTLProvider = Provider<bool>((ref) {
  // Compute RTL from locale directly instead of asking LanguageService
  // (avoids subscribing to the full ChangeNotifier).
  final langCode = ref.watch(localeStateNotifierProvider).languageCode;
  return langCode == 'ar';
});

/// Display name for the current locale (e.g. "Français", "English", "العربية").
/// Rebuilds when locale changes. Use this in UI instead of reading
/// languageService.currentLanguageName directly.
final currentLanguageNameProvider = Provider<String>((ref) {
  final locale = ref.watch(localeStateNotifierProvider);
  return ref.read(languageServiceProvider).getLanguageName(locale.languageCode);
});

// ============================================================================
// PERMISSIONS
// ============================================================================

// .autoDispose added in previous /state-apply session — unchanged.
final hasLocationPermissionProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await ref.watch(permissionServiceProvider).hasLocationPermission();
  } catch (e) { _logError('hasLocationPermissionProvider', e); return false; }
});

final hasAllCriticalPermissionsProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await ref.watch(permissionServiceProvider).areAllCriticalPermissionsGranted();
  } catch (e) { _logError('hasAllCriticalPermissionsProvider', e); return false; }
});

// ============================================================================
// PROFILE PROVIDERS
// ============================================================================

final userProfileProvider = FutureProvider.family
    .autoDispose<UserModel?, String>((ref, String userId) async {
  final firestoreService = ref.watch(firestoreServiceProvider);
  if (userId.trim().isEmpty) throw ArgumentError('User ID cannot be empty');
  try {
    return await firestoreService.getUser(userId);
  } catch (e) { _logError('userProfileProvider($userId)', e); rethrow; }
});

final workerProfileProvider = FutureProvider.family
    .autoDispose<WorkerModel?, String>((ref, String workerId) async {
  final firestoreService = ref.watch(firestoreServiceProvider);
  if (workerId.trim().isEmpty) throw ArgumentError('Worker ID cannot be empty');
  try {
    return await firestoreService.getWorker(workerId);
  } catch (e) { _logError('workerProfileProvider($workerId)', e); rethrow; }
});

final serviceRequestProvider = FutureProvider.family
    .autoDispose<ServiceRequestEnhancedModel?, String>((ref, String requestId) async {
  final firestoreService = ref.watch(firestoreServiceProvider);
  if (requestId.trim().isEmpty) throw ArgumentError('Request ID cannot be empty');
  try {
    return await firestoreService.getServiceRequest(requestId);
  } catch (e) { _logError('serviceRequestProvider($requestId)', e); rethrow; }
});

// ============================================================================
// STREAM PROVIDERS
// ============================================================================

final userServiceRequestsStreamProvider = StreamProvider.family
    .autoDispose<List<ServiceRequestEnhancedModel>, String>((ref, String userId) {
  final firestoreService = ref.watch(firestoreServiceProvider);
  if (userId.trim().isEmpty)
    return Stream.error(ArgumentError('User ID cannot be empty'));
  try {
    return firestoreService.streamUserServiceRequests(userId);
  } catch (e) { _logError('userServiceRequestsStreamProvider', e); return Stream.error(e); }
});

final workerServiceRequestsStreamProvider = StreamProvider.family
    .autoDispose<List<ServiceRequestEnhancedModel>, String>((ref, String workerId) {
  final firestoreService = ref.watch(firestoreServiceProvider);
  if (workerId.trim().isEmpty)
    return Stream.error(ArgumentError('Worker ID cannot be empty'));
  try {
    return firestoreService.streamWorkerServiceRequests(workerId);
  } catch (e) { _logError('workerServiceRequestsStreamProvider', e); return Stream.error(e); }
});

final serviceRequestStreamProvider = StreamProvider.family
    .autoDispose<ServiceRequestEnhancedModel?, String>((ref, String requestId) {
  final firestoreService = ref.watch(firestoreServiceProvider);
  if (requestId.trim().isEmpty)
    return Stream.error(ArgumentError('Request ID cannot be empty'));
  try {
    return firestoreService.streamServiceRequest(requestId);
  } catch (e) { _logError('serviceRequestStreamProvider', e); return Stream.error(e); }
});

final bidsStreamProvider = StreamProvider.family
    .autoDispose<List<WorkerBidModel>, String>((ref, String requestId) {
  final bidService = ref.watch(workerBidServiceProvider);
  if (requestId.trim().isEmpty)
    return Stream.error(ArgumentError('Request ID cannot be empty'));
  try {
    return bidService.streamBidsForRequest(requestId);
  } catch (e) { _logError('bidsStreamProvider', e); return Stream.error(e); }
});

final availableRequestsStreamProvider = StreamProvider.family.autoDispose<
    List<ServiceRequestEnhancedModel>,
    ({int wilayaCode, String serviceType})>((ref, params) {
  final bidService = ref.watch(workerBidServiceProvider);
  try {
    return bidService.streamAvailableRequests(
        wilayaCode: params.wilayaCode, serviceType: params.serviceType);
  } catch (e) { _logError('availableRequestsStreamProvider', e); return Stream.error(e); }
});

final workerActiveJobsStreamProvider = StreamProvider.family
    .autoDispose<List<ServiceRequestEnhancedModel>, String>((ref, String workerId) {
  final bidService = ref.watch(workerBidServiceProvider);
  if (workerId.trim().isEmpty)
    return Stream.error(ArgumentError('Worker ID cannot be empty'));
  try {
    return bidService.streamWorkerActiveJobs(workerId);
  } catch (e) { _logError('workerActiveJobsStreamProvider', e); return Stream.error(e); }
});

final workerBidsStreamProvider = StreamProvider.family
    .autoDispose<List<WorkerBidModel>, String>((ref, String workerId) {
  final bidService = ref.watch(workerBidServiceProvider);
  if (workerId.trim().isEmpty)
    return Stream.error(ArgumentError('Worker ID cannot be empty'));
  try {
    return bidService.streamWorkerBids(workerId);
  } catch (e) { _logError('workerBidsStreamProvider', e); return Stream.error(e); }
});

// ============================================================================
// UTILITY
// ============================================================================

final servicesInitializedProvider = Provider<bool>((ref) {
  try {
    ref.watch(firestoreServiceProvider);
    ref.watch(authServiceProvider);
    ref.watch(languageServiceProvider);
    _logInfo('All services initialized successfully');
    return true;
  } catch (e) {
    _logError('servicesInitializedProvider', e);
    rethrow;
  }
});

// ============================================================================
// PROVIDER OBSERVER
// ============================================================================

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
      debugPrint('[Provider] FAILED: ${p.name ?? p.runtimeType}');
      debugPrint('[Provider] Error: $e');
    }
  }
}

// ============================================================================
// LOGGING
// ============================================================================

void _logInfo(String message) {
  if (kDebugMode) debugPrint('[CoreProviders] INFO: $message');
}
void _logError(String provider, dynamic error) {
  if (kDebugMode) debugPrint('[CoreProviders] ERROR in $provider: $error');
}
