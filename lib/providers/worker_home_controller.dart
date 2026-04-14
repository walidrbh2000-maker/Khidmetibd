// lib/providers/worker_home_controller.dart
//
// TASK 2 FIX — Removed direct FirebaseFirestore.instance usage.
//
// WHAT CHANGED:
//   • _subscribeToWorker(): replaced FirebaseFirestore.instance.collection(...)
//     .doc(uid).snapshots() with firestoreServiceProvider.streamWorker(uid).
//     The stream now returns WorkerModel? (typed) instead of a raw
//     DocumentSnapshot, so doc.exists / fromMap parsing is removed from here.
//   • _subscribeToRequests(): replaced FirebaseFirestore.instance.collection(...)
//     .where('workerId',...).snapshots() with
//     firestoreServiceProvider.streamWorkerAssignedRequests(workerId, limit: 30).
//     The stream now returns List<ServiceRequestEnhancedModel> directly.
//   • _workerSub type: DocumentSnapshot<...> → WorkerModel?
//   • _requestsSub type: QuerySnapshot<...> → List<ServiceRequestEnhancedModel>
//   • Removed: `import 'package:cloud_firestore/cloud_firestore.dart'` —
//     no Firestore types remain in this controller.
//   • Removed: `import '../services/firestore_service.dart'` (collection
//     constants were only needed for the inline queries).
//
// FIX (MIGRATION P2 — streamWorker null):
//   RealtimeService.streamWorker() émet `null` comme signal de changement
//   (location update, status change) — pas comme indication que le profil
//   n'existe pas. L'ancien code traitait null comme une erreur fatale et
//   set AsyncError, ce qui causait un flash d'erreur dans le HomeScreen à
//   chaque mise à jour de localisation.
//
//   AVANT : null → state = AsyncError('Worker profile not found')
//   APRÈS : null → re-fetch via getWorker(uid) et mettre à jour silencieusement.
//           Si le re-fetch échoue réellement → alors et seulement alors, error.
//
// FIX (Bug 1a — _subscribeToRequests manquant après re-fetch null):
//   Quand le premier événement du stream est null (cas courant au démarrage
//   avec RealtimeService), le re-fetch réussi mettait bien à jour workerAsync
//   mais n'appelait jamais _subscribeToRequests(). La souscription aux
//   requêtes n'était donc jamais initialisée → section vide.
//
// FIX (Bug 1b — catch silencieux → AsyncLoading permanent):
//   Si le re-fetch échouait lors du premier chargement (state = AsyncLoading),
//   le catch ne faisait rien → le state restait AsyncLoading indéfiniment →
//   HomeWorkerSection retournait SizedBox.shrink() pour toujours.
//   Correction : escalade vers AsyncError UNIQUEMENT si encore en AsyncLoading
//   (ne pas écraser les données existantes en cas de blip réseau).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message_enums.dart';
import '../models/service_request_enhanced_model.dart';
import '../models/worker_model.dart';
import '../providers/core_providers.dart';
import '../providers/location_controller.dart';
import '../providers/location_permission_controller.dart';
import '../utils/logger.dart';

// ============================================================================
// WORKER HOME STATE
// ============================================================================

enum GoOnlineBlockReason {
  permissionDenied,
  permissionPermanentlyDenied,
  gpsHardwareDisabled,
}

class WorkerHomeState {
  final AsyncValue<WorkerModel> workerAsync;
  final bool isTogglingOnline;
  final List<ServiceRequestEnhancedModel> recentRequests;
  final bool isLoadingRequests;
  final String? requestsError;
  final bool isRefreshing;
  final String? toggleError;
  final GoOnlineBlockReason? goOnlineBlockReason;

  const WorkerHomeState({
    this.workerAsync = const AsyncValue.loading(),
    this.isTogglingOnline = false,
    this.recentRequests = const [],
    this.isLoadingRequests = false,
    this.requestsError,
    this.isRefreshing = false,
    this.toggleError,
    this.goOnlineBlockReason,
  });

  int get pendingCount =>
      recentRequests.where((r) => r.status == ServiceStatus.pending).length;

  int get activeCount => recentRequests
      .where((r) =>
          r.status == ServiceStatus.accepted ||
          r.status == ServiceStatus.inProgress)
      .length;

  int get completedCount =>
      recentRequests.where((r) => r.status == ServiceStatus.completed).length;

  WorkerModel? get worker      => workerAsync.value;
  bool get isOnline            => worker?.isOnline ?? false;
  bool get isWorkerLoaded      => workerAsync is AsyncData;
  bool get isWorkerLoading     => workerAsync is AsyncLoading;
  bool get isWorkerError       => workerAsync is AsyncError;

  WorkerHomeState copyWith({
    AsyncValue<WorkerModel>? workerAsync,
    bool? isTogglingOnline,
    List<ServiceRequestEnhancedModel>? recentRequests,
    bool? isLoadingRequests,
    String? requestsError,
    bool? isRefreshing,
    String? toggleError,
    GoOnlineBlockReason? goOnlineBlockReason,
    bool clearToggleError         = false,
    bool clearRequestsError       = false,
    bool clearGoOnlineBlockReason = false,
  }) {
    return WorkerHomeState(
      workerAsync:       workerAsync       ?? this.workerAsync,
      isTogglingOnline:  isTogglingOnline  ?? this.isTogglingOnline,
      recentRequests:    recentRequests    ?? this.recentRequests,
      isLoadingRequests: isLoadingRequests ?? this.isLoadingRequests,
      requestsError: clearRequestsError
          ? null
          : (requestsError ?? this.requestsError),
      isRefreshing: isRefreshing ?? this.isRefreshing,
      toggleError:  clearToggleError ? null : (toggleError ?? this.toggleError),
      goOnlineBlockReason: clearGoOnlineBlockReason
          ? null
          : (goOnlineBlockReason ?? this.goOnlineBlockReason),
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class WorkerHomeController extends StateNotifier<WorkerHomeState> {
  final Ref _ref;

  // TASK 2 FIX: type changed to match the typed stream returns.
  StreamSubscription<WorkerModel?>?                         _workerSub;
  StreamSubscription<List<ServiceRequestEnhancedModel>>?    _requestsSub;

  /// uid conservé pour le re-fetch silencieux sur null de streamWorker.
  String? _trackedUid;

  WorkerHomeController(this._ref) : super(const WorkerHomeState()) {
    _initialize();
  }

  // --------------------------------------------------------------------------
  // Public API
  // --------------------------------------------------------------------------

  Future<void> toggleOnlineStatus() async {
    if (state.isTogglingOnline) return;
    final worker = state.worker;
    if (worker == null) return;

    final newIsOnline = !worker.isOnline;

    if (newIsOnline) {
      final blockReason = await _resolveGoOnlineBlockReason();
      if (blockReason != null) {
        AppLogger.warning(
            'WorkerHomeController: Go Online blocked — $blockReason');
        state = state.copyWith(goOnlineBlockReason: blockReason);
        return;
      }
    }

    AppLogger.info(
        'WorkerHomeController: toggling online → $newIsOnline for ${worker.id}');

    state = state.copyWith(
      isTogglingOnline:         true,
      clearToggleError:         true,
      clearGoOnlineBlockReason: true,
    );

    try {
      if (newIsOnline) {
        try {
          final locationNotifier =
              _ref.read(userLocationControllerProvider.notifier);
          await locationNotifier.retryLocation();

          final locationState = _ref.read(userLocationControllerProvider);
          if (locationState.userLocation != null) {
            await _ref.read(firestoreServiceProvider).updateWorkerLocation(
              worker.id,
              locationState.userLocation!.latitude,
              locationState.userLocation!.longitude,
            );
            AppLogger.info(
                'WorkerHomeController: GPS captured — '
                '${locationState.userLocation!.latitude}, '
                '${locationState.userLocation!.longitude}');
          }
        } catch (gpsError) {
          AppLogger.warning(
              'WorkerHomeController: GPS refresh failed — '
              'going online without live coords: $gpsError');
        }

        try {
          final locState = _ref.read(userLocationControllerProvider);
          if (locState.userLocation != null) {
            final gridService = _ref.read(geographicGridServiceProvider);
            await gridService.assignWorkerToCell(
              workerId:  worker.id,
              latitude:  locState.userLocation!.latitude,
              longitude: locState.userLocation!.longitude,
            );
            AppLogger.info(
                'WorkerHomeController: worker assigned to geographic cell');
          }
        } catch (cellError) {
          AppLogger.warning(
              'WorkerHomeController: geographic cell assignment failed '
              '(non-fatal): $cellError');
        }

        try {
          final nativeService = _ref.read(nativeChannelServiceProvider);
          await nativeService.startLocationService(
            userId:   worker.id,
            isWorker: true,
          );
          AppLogger.info(
              'WorkerHomeController: background location service started');
        } catch (e) {
          AppLogger.warning(
              'WorkerHomeController: native location service start failed: $e');
        }
      } else {
        try {
          final nativeService = _ref.read(nativeChannelServiceProvider);
          await nativeService.stopLocationService();
          AppLogger.info(
              'WorkerHomeController: background location service stopped');
        } catch (e) {
          AppLogger.warning(
              'WorkerHomeController: native location service stop failed: $e');
        }
      }

      await _ref
          .read(firestoreServiceProvider)
          .updateWorkerStatus(worker.id, newIsOnline)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'Worker status update timed out after 10 seconds',
            ),
          );

      AppLogger.info(
          'WorkerHomeController: online status updated → $newIsOnline');
    } catch (e) {
      AppLogger.error('WorkerHomeController.toggleOnlineStatus', e);
      if (!mounted) return;
      state = state.copyWith(toggleError: e.toString());
    } finally {
      if (mounted) state = state.copyWith(isTogglingOnline: false);
    }
  }

  Future<void> acceptRequest(String requestId) async {
    AppLogger.info('WorkerHomeController: accepting request $requestId');
    await _updateRequestStatus(requestId, ServiceStatus.accepted);
  }

  Future<void> declineRequest(String requestId) async {
    AppLogger.info('WorkerHomeController: declining request $requestId');
    await _updateRequestStatus(requestId, ServiceStatus.declined);
  }

  Future<void> markInProgress(String requestId) async {
    AppLogger.info('WorkerHomeController: marking in-progress $requestId');
    await _updateRequestStatus(requestId, ServiceStatus.inProgress);
  }

  Future<void> markCompleted(String requestId) async {
    AppLogger.info('WorkerHomeController: marking completed $requestId');
    await _updateRequestStatus(requestId, ServiceStatus.completed);
  }

  Future<void> refresh() async {
    if (state.isRefreshing) return;
    state = state.copyWith(isRefreshing: true);
    try {
      final uid = _trackedUid;
      if (uid != null) {
        // Re-fetch le profil worker directement pour forcer un refresh propre.
        final refreshed = await _ref
            .read(firestoreServiceProvider)
            .getWorker(uid);
        if (!mounted) return;
        if (refreshed != null) {
          state = state.copyWith(workerAsync: AsyncValue.data(refreshed));
          await _loadRequests(uid);
        }
      }
    } catch (e) {
      AppLogger.error('WorkerHomeController.refresh', e);
    } finally {
      if (mounted) state = state.copyWith(isRefreshing: false);
    }
  }

  void clearToggleError() =>
      state = state.copyWith(clearToggleError: true);

  void clearGoOnlineBlock() =>
      state = state.copyWith(clearGoOnlineBlockReason: true);

  // --------------------------------------------------------------------------
  // Private — GPS / permission gate
  // --------------------------------------------------------------------------

  Future<GoOnlineBlockReason?> _resolveGoOnlineBlockReason() async {
    final permState = _ref.read(locationPermissionControllerProvider);

    try {
      final locationService = _ref.read(locationServiceProvider);
      final gpsOn = await locationService.isLocationServiceEnabled();
      if (!gpsOn) {
        _ref
            .read(locationPermissionControllerProvider.notifier)
            .recheck();
        return GoOnlineBlockReason.gpsHardwareDisabled;
      }
    } catch (e) {
      AppLogger.warning(
          'WorkerHomeController: GPS hardware check failed — '
          'blocking as a precaution: $e');
      return GoOnlineBlockReason.gpsHardwareDisabled;
    }

    if (permState.needsSettings) {
      return GoOnlineBlockReason.permissionPermanentlyDenied;
    }
    if (!permState.isGranted) {
      return GoOnlineBlockReason.permissionDenied;
    }

    return null;
  }

  // --------------------------------------------------------------------------
  // Private — initialisation
  // --------------------------------------------------------------------------

  void _initialize() {
    final authService = _ref.read(authServiceProvider);
    final uid = authService.user?.uid;

    if (uid == null) {
      AppLogger.warning(
          'WorkerHomeController: no authenticated user — aborting');
      state = state.copyWith(
        workerAsync: AsyncValue.error(
            Exception('User not authenticated'), StackTrace.current),
      );
      return;
    }

    _trackedUid = uid;
    AppLogger.info('WorkerHomeController: initialising for uid=$uid');
    _subscribeToWorker(uid);
  }

  // --------------------------------------------------------------------------
  // TASK 2 FIX — stream via firestoreServiceProvider
  // FIX (MIGRATION P2) — null = signal de changement, pas une erreur fatale
  // FIX (Bug 1a) — appel _subscribeToRequests() après re-fetch réussi
  // FIX (Bug 1b) — escalade AsyncError si encore en AsyncLoading
  // --------------------------------------------------------------------------

  void _subscribeToWorker(String uid) {
    _workerSub?.cancel();
    _workerSub = _ref
        .read(firestoreServiceProvider)
        .streamWorker(uid)
        .listen(
      (worker) async {
        if (!mounted) return;

        if (worker == null) {
          // RealtimeService émet null comme signal de changement
          // (location update, status change) — pas comme "profil introuvable".
          // On re-fetch silencieusement pour obtenir les données à jour.
          AppLogger.debug(
            'WorkerHomeController: streamWorker emitted null '
            '(change signal) — re-fetching uid=$uid',
          );
          try {
            final refreshed = await _ref
                .read(firestoreServiceProvider)
                .getWorker(uid);
            if (!mounted) return;

            if (refreshed != null) {
              state = state.copyWith(workerAsync: AsyncValue.data(refreshed));
              // FIX (Bug 1a): appeler _subscribeToRequests après re-fetch
              // réussi. Sans cet appel, si le PREMIER événement du stream est
              // null (fréquent au démarrage), la souscription aux requêtes
              // n'est jamais initialisée et la section reste vide.
              _subscribeToRequests(uid);
            } else {
              // Le profil n'existe vraiment pas — erreur légitime.
              state = state.copyWith(
                workerAsync: AsyncValue.error(
                  Exception('Worker profile not found'),
                  StackTrace.current,
                ),
              );
            }
          } catch (e, st) {
            AppLogger.warning(
              'WorkerHomeController: re-fetch after null signal failed: $e',
            );
            if (!mounted) return;
            // FIX (Bug 1b): le catch silencieux laissait le state bloqué en
            // AsyncLoading si le re-fetch échouait lors du premier chargement.
            // HomeWorkerSection ne sortait jamais de `isWorkerLoading → shrink`.
            //
            // Règle : escalader vers AsyncError UNIQUEMENT si on est encore en
            // AsyncLoading. Si on avait déjà des données (AsyncData), un blip
            // réseau ne doit pas effacer l'UI existante.
            if (state.workerAsync is AsyncLoading) {
              state = state.copyWith(
                workerAsync: AsyncValue.error(e, st),
              );
            }
          }
          return;
        }

        AppLogger.debug(
            'WorkerHomeController: worker snapshot — online=${worker.isOnline}');
        state = state.copyWith(workerAsync: AsyncValue.data(worker));
        _subscribeToRequests(uid);
      },
      onError: (Object error) {
        AppLogger.error('WorkerHomeController._subscribeToWorker', error);
        if (!mounted) return;
        state = state.copyWith(
          workerAsync: AsyncValue.error(error, StackTrace.current),
        );
      },
    );
  }

  /// TASK 2 FIX: replaced FirebaseFirestore.instance.collection(
  /// 'service_requests').where('workerId',...).limit(30).snapshots()
  /// with firestoreServiceProvider.streamWorkerAssignedRequests(workerId).
  void _subscribeToRequests(String workerId) {
    if (_requestsSub != null) return;

    AppLogger.info(
        'WorkerHomeController: subscribing to requests for $workerId');
    state = state.copyWith(
      isLoadingRequests:  true,
      clearRequestsError: true,
    );

    _requestsSub = _ref
        .read(firestoreServiceProvider)
        .streamWorkerAssignedRequests(workerId, limit: 30)
        .listen(
      (requests) {
        if (!mounted) return;
        AppLogger.info(
            'WorkerHomeController: loaded ${requests.length} requests');
        state = state.copyWith(
          recentRequests:    requests,
          isLoadingRequests: false,
        );
      },
      onError: (Object error) {
        AppLogger.error('WorkerHomeController._subscribeToRequests', error);
        if (!mounted) return;
        state = state.copyWith(
          isLoadingRequests: false,
          requestsError:     error.toString(),
        );
      },
    );
  }

  Future<void> _loadRequests(String workerId) async {
    _requestsSub?.cancel();
    _requestsSub = null;
    _subscribeToRequests(workerId);
  }

  Future<void> _updateRequestStatus(
    String requestId,
    ServiceStatus newStatus, {
    DateTime? completedAt,
  }) async {
    try {
      final firestoreService = _ref.read(firestoreServiceProvider);

      switch (newStatus) {
        case ServiceStatus.accepted:
        case ServiceStatus.inProgress:
          await firestoreService.startJob(requestId);
          break;

        case ServiceStatus.completed:
          await firestoreService.completeJob(requestId: requestId);
          break;

        case ServiceStatus.declined:
        case ServiceStatus.cancelled:
          await firestoreService.cancelRequest(requestId);
          break;

        default:
          AppLogger.warning(
              'WorkerHomeController._updateRequestStatus: '
              'unhandled status $newStatus for $requestId — skipping');
          return;
      }

      AppLogger.info(
          'WorkerHomeController: request $requestId → $newStatus');
    } catch (e) {
      AppLogger.error('WorkerHomeController._updateRequestStatus', e);
      rethrow;
    }
  }

  @override
  void dispose() {
    AppLogger.debug('WorkerHomeController: disposing');
    _workerSub?.cancel();
    _requestsSub?.cancel();
    super.dispose();
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final workerHomeControllerProvider =
    StateNotifierProvider.autoDispose<WorkerHomeController, WorkerHomeState>(
  (ref) {
    final link = ref.keepAlive();
    ref.listen<bool>(isLoggedInProvider, (_, isLoggedIn) {
      if (!isLoggedIn) link.close();
    });
    return WorkerHomeController(ref);
  },
);
