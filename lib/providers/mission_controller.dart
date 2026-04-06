// lib/providers/mission_controller.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/worker_bid_service.dart';
import 'core_providers.dart';

// ============================================================================
// STATE
// ============================================================================

class MissionState {
  final bool isLoading;
  final String? errorMessage;
  final bool success;

  const MissionState({
    this.isLoading = false,
    this.errorMessage,
    this.success = false,
  });

  MissionState copyWith({
    bool? isLoading,
    String? errorMessage,
    bool? success,
    bool clearError = false,
  }) {
    return MissionState(
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      success: success ?? this.success,
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

/// Owns the action lifecycle (startJob / completeJob) for a single active
/// mission card, keyed on the service request ID.
///
/// Using a family provider means each card in the list gets its own isolated
/// loading state — pressing "Start" on card A never disables card B.
class MissionController extends StateNotifier<MissionState> {
  final WorkerBidService _bidService;

  MissionController(this._bidService) : super(const MissionState());

  Future<void> startJob(String requestId) async {
    if (state.isLoading) return;
    if (!mounted) return;

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _bidService.startJob(requestId);
      if (!mounted) return;
      state = state.copyWith(isLoading: false, success: true);
    } on WorkerBidServiceException catch (e) {
      _handleError(e.message);
    } catch (e) {
      _logError('startJob', e);
      _handleError(e.toString());
    }
  }

  Future<void> completeJob({
    required String requestId,
    String? workerNotes,
    double? finalPrice,
  }) async {
    if (state.isLoading) return;
    if (!mounted) return;

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _bidService.completeJob(
        requestId: requestId,
        workerNotes: workerNotes,
        finalPrice: finalPrice,
      );
      if (!mounted) return;
      state = state.copyWith(isLoading: false, success: true);
    } on WorkerBidServiceException catch (e) {
      _handleError(e.message);
    } catch (e) {
      _logError('completeJob', e);
      _handleError(e.toString());
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void _handleError(String message) {
    if (!mounted) return;
    state = state.copyWith(isLoading: false, errorMessage: message);
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[MissionController] ERROR in $method: $error');
    }
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final missionControllerProvider = StateNotifierProvider.autoDispose
    .family<MissionController, MissionState, String>(
  (ref, requestId) => MissionController(ref.read(workerBidServiceProvider)),
);
