// lib/providers/available_requests_controller.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/service_request_enhanced_model.dart';
import '../models/worker_bid_model.dart';
import '../models/message_enums.dart';
import '../models/worker_model.dart';
import 'core_providers.dart';

// ============================================================================
// FILTER ENUM
// ============================================================================

enum AvailableRequestsFilter {
  all,
  urgent,
  highBudget,
  noBids,
}

extension AvailableRequestsFilterLabel on AvailableRequestsFilter {
  String label(String Function(String) tr) {
    switch (this) {
      case AvailableRequestsFilter.all:
        return tr('worker_browse.filter_all');
      case AvailableRequestsFilter.urgent:
        return tr('worker_browse.filter_urgent');
      case AvailableRequestsFilter.highBudget:
        return tr('worker_browse.filter_high_budget');
      case AvailableRequestsFilter.noBids:
        return tr('worker_browse.filter_no_bids');
    }
  }
}

// ============================================================================
// STATE
// ============================================================================

class AvailableRequestsState {
  // FIX (P2, P5): replaced isLoading + errorMessage + allRequests triple with
  // AsyncValue<List<ServiceRequestEnhancedModel>> — matches workerJobsController
  // gold-standard pattern. Backward-compat getters preserve all call sites.
  final AsyncValue<List<ServiceRequestEnhancedModel>> requestsAsync;

  final AvailableRequestsFilter activeFilter;

  // Maintained by AvailableRequestsController._bidsSub — the set of request
  // IDs where the current worker has a PENDING bid.
  final Set<String> pendingBidRequestIds;

  // FIX (Performance): memoized filtered list — recomputed only when
  // allRequests or activeFilter changes, not on pendingBidRequestIds updates.
  // FIX (🔴 Critical — S2-cache-bug): _cacheValid sentinel guards against
  // stale cache returning const [] after data update.
  final bool _cacheValid;
  final List<ServiceRequestEnhancedModel> _cachedFilteredRequests;
  final AvailableRequestsFilter _cachedFilterKey;

  const AvailableRequestsState({
    this.requestsAsync = const AsyncValue.loading(),
    this.activeFilter = AvailableRequestsFilter.all,
    this.pendingBidRequestIds = const {},
    bool cacheValid = false,
    List<ServiceRequestEnhancedModel>? cachedFiltered,
    AvailableRequestsFilter? cachedFilterKey,
  })  : _cacheValid = cacheValid,
        _cachedFilteredRequests = cachedFiltered ?? const [],
        _cachedFilterKey = cachedFilterKey ?? AvailableRequestsFilter.all;

  // ── Backward-compat getters — all call sites unchanged ───────────────────

  /// All loaded requests, or empty list while loading/erroring.
  List<ServiceRequestEnhancedModel> get allRequests =>
      requestsAsync.asData?.value ?? const [];

  /// True while the requests stream is initialising or re-loading.
  bool get isLoading => requestsAsync.isLoading;

  /// Error string if the stream failed, null otherwise.
  String? get errorMessage => requestsAsync.asError?.error.toString();

  // ─────────────────────────────────────────────────────────────────────────

  /// Returns true if the current worker already has a pending bid on [requestId].
  bool hasMyBid(String requestId) =>
      pendingBidRequestIds.contains(requestId);

  /// Filtered and sorted list — memoized: re-runs only when allRequests or
  /// activeFilter change, not on every pendingBidRequestIds update.
  List<ServiceRequestEnhancedModel> get filteredRequests {
    if (_cacheValid && _cachedFilterKey == activeFilter) {
      return _cachedFilteredRequests;
    }
    return _computeFiltered();
  }

  List<ServiceRequestEnhancedModel> _computeFiltered() {
    switch (activeFilter) {
      case AvailableRequestsFilter.all:
        return allRequests;
      case AvailableRequestsFilter.urgent:
        return allRequests
            .where((r) => r.priority == ServicePriority.urgent)
            .toList();
      case AvailableRequestsFilter.highBudget:
        return allRequests
            .where((r) => r.budgetMax != null && r.budgetMax! >= 5000)
            .toList()
          ..sort((a, b) =>
              (b.budgetMax ?? 0).compareTo(a.budgetMax ?? 0));
      case AvailableRequestsFilter.noBids:
        return allRequests.where((r) => r.bidCount == 0).toList();
    }
  }

  AvailableRequestsState copyWith({
    AsyncValue<List<ServiceRequestEnhancedModel>>? requestsAsync,
    AvailableRequestsFilter? activeFilter,
    Set<String>? pendingBidRequestIds,
    // Internal — set automatically when requestsAsync or activeFilter changes.
    bool invalidateFilterCache = false,
  }) {
    final newActiveFilter  = activeFilter ?? this.activeFilter;
    final cacheInvalidated = invalidateFilterCache ||
        requestsAsync != null ||
        activeFilter != null;

    return AvailableRequestsState(
      requestsAsync:        requestsAsync        ?? this.requestsAsync,
      activeFilter:         newActiveFilter,
      pendingBidRequestIds: pendingBidRequestIds ?? this.pendingBidRequestIds,
      cacheValid:     !cacheInvalidated,
      cachedFiltered: cacheInvalidated ? null : _cachedFilteredRequests,
      cachedFilterKey: cacheInvalidated ? newActiveFilter : _cachedFilterKey,
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class AvailableRequestsController
    extends StateNotifier<AvailableRequestsState> {
  final Ref _ref;
  StreamSubscription<List<ServiceRequestEnhancedModel>>? _requestsSub;
  StreamSubscription<List<WorkerBidModel>>?              _bidsSub;

  WorkerModel? _worker;
  String?      _workerId;

  AvailableRequestsController(this._ref)
      : super(const AvailableRequestsState()) {
    _init();
  }

  Future<void> _init() async {
    final userId = _ref.read(currentUserIdProvider);
    if (userId == null) return;
    _workerId = userId;

    try {
      final firestoreService = _ref.read(firestoreServiceProvider);
      _worker = await firestoreService.getWorker(userId);

      if (_worker == null) {
        if (!mounted) return;
        state = state.copyWith(
          requestsAsync: AsyncValue.error(
            'worker_not_found',
            StackTrace.current,
          ),
        );
        return;
      }

      _subscribeToRequests();
      _subscribeToBids(userId);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[AvailableRequestsController] ERROR in _init: $e');
      }
      if (!mounted) return;
      state = state.copyWith(
        requestsAsync: AsyncValue.error(e, st),
      );
    }
  }

  void _subscribeToRequests() {
    if (_worker == null) return;

    state = state.copyWith(
      requestsAsync: const AsyncValue.loading(),
    );

    _requestsSub?.cancel();
    _requestsSub = _ref
        .read(firestoreServiceProvider)
        .streamAvailableRequests(
          wilayaCode:  _worker!.wilayaCode ?? 31,
          serviceType: _worker!.profession,
        )
        .listen(
      (requests) {
        if (!mounted) return;
        state = state.copyWith(
          requestsAsync: AsyncValue.data(requests),
          // cache invalidation is implicit: requestsAsync != null
        );
      },
      onError: (e, StackTrace st) {
        if (!mounted) return;
        state = state.copyWith(
          requestsAsync: AsyncValue.error(e, st),
        );
      },
    );
  }

  void _subscribeToBids(String workerId) {
    _bidsSub?.cancel();
    _bidsSub = _ref
        .read(firestoreServiceProvider)
        .streamWorkerBids(workerId)
        .listen(
      (bids) {
        if (!mounted) return;
        final pendingIds = bids
            .where((b) => b.status == BidStatus.pending)
            .map((b) => b.serviceRequestId)
            .toSet();
        // Only pendingBidRequestIds changes — filteredRequests cache is NOT
        // invalidated, avoiding an unnecessary re-sort of the full list.
        state = state.copyWith(pendingBidRequestIds: pendingIds);
      },
      onError: (e) {
        // Non-fatal: bids stream failure does not block the requests list.
        if (kDebugMode) {
          debugPrint(
              '[AvailableRequestsController] WARNING: bids stream error: $e');
        }
      },
    );
  }

  void setFilter(AvailableRequestsFilter filter) {
    if (!mounted) return;
    state = state.copyWith(activeFilter: filter);
    // cache invalidation is implicit: activeFilter != null
  }

  void refresh() {
    if (_worker == null || _workerId == null) {
      _init();
      return;
    }
    _subscribeToRequests();
    _subscribeToBids(_workerId!);
  }

  @override
  void dispose() {
    _requestsSub?.cancel();
    _bidsSub?.cancel();
    super.dispose();
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final availableRequestsControllerProvider = StateNotifierProvider.autoDispose<
    AvailableRequestsController, AvailableRequestsState>(
  (ref) => AvailableRequestsController(ref),
);
