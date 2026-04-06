// lib/providers/job_action_controller.dart
//
// FIX (S2 — worker_jobs_controller.dart): per-job action state was stored in
// Maps<String, JobActionStatus> on a single StateNotifier, meaning any single
// job action triggered a full state copy + rebuild of every watching widget.
//
// This file provides a StateNotifierProvider.autoDispose.family keyed on jobId,
// mirroring the MissionController pattern already used in this codebase.
// Each job card gets its own isolated loading/error state — pressing "Accept"
// on card A never causes card B to rebuild.
//
// MIGRATION: Widgets that previously read:
//   ref.watch(workerJobsControllerProvider).actionStatusFor(jobId)
//   ref.watch(workerJobsControllerProvider).actionErrorFor(jobId)
// should now watch:
//   ref.watch(jobActionControllerProvider(jobId)).status
//   ref.watch(jobActionControllerProvider(jobId)).errorMessage
//
// Action methods that previously called workerJobsController.acceptJob(id)
// should now call:
//   ref.read(jobActionControllerProvider(jobId).notifier).startJob(jobId)

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message_enums.dart';
import '../services/worker_bid_service.dart';
import 'core_providers.dart';

// ============================================================================
// ENUMS  (re-exported so widgets that imported from worker_jobs_controller
//         can switch imports without renaming)
// ============================================================================

enum JobActionStatus { idle, loading, success, error }

// ============================================================================
// STATE
// ============================================================================

class JobActionState {
  final JobActionStatus status;
  final String?         errorMessage;

  const JobActionState({
    this.status       = JobActionStatus.idle,
    this.errorMessage,
  });

  bool get isLoading => status == JobActionStatus.loading;
  bool get isSuccess => status == JobActionStatus.success;
  bool get hasError  => status == JobActionStatus.error;

  JobActionState copyWith({
    JobActionStatus? status,
    String?          errorMessage,
    bool             clearError = false,
  }) {
    return JobActionState(
      status:       status       ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

/// Owns the action lifecycle (startJob / completeJob / declineJob) for a
/// single job card, keyed on the service request ID.
///
/// Using .family means each card gets its own isolated loading state —
/// accepting job A never disables job B.
class JobActionController extends StateNotifier<JobActionState> {
  final WorkerBidService  _bidService;
  final Ref               _ref;
  final String            _jobId;

  JobActionController(this._bidService, this._ref, this._jobId)
      : super(const JobActionState());

  // --------------------------------------------------------------------------
  // Accept / Start Job
  // --------------------------------------------------------------------------

  Future<void> startJob() async {
    if (state.isLoading || !mounted) return;
    state = state.copyWith(status: JobActionStatus.loading, clearError: true);
    try {
      await _bidService.startJob(_jobId);
      if (!mounted) return;
      state = state.copyWith(status: JobActionStatus.success);
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) state = const JobActionState();
    } on WorkerBidServiceException catch (e) {
      _handleError(e.message);
    } catch (e) {
      _logError('startJob', e);
      _handleError(e.toString());
    }
  }

  // --------------------------------------------------------------------------
  // Complete Job
  // --------------------------------------------------------------------------

  Future<void> completeJob({String? notes, double? finalPrice}) async {
    if (state.isLoading || !mounted) return;
    state = state.copyWith(status: JobActionStatus.loading, clearError: true);
    try {
      await _bidService.completeJob(
        requestId:   _jobId,
        workerNotes: notes,
        finalPrice:  finalPrice,
      );
      if (!mounted) return;
      state = state.copyWith(status: JobActionStatus.success);
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) state = const JobActionState();
    } on WorkerBidServiceException catch (e) {
      _handleError(e.message);
    } catch (e) {
      _logError('completeJob', e);
      _handleError(e.toString());
    }
  }

  // --------------------------------------------------------------------------
  // Decline Job
  // --------------------------------------------------------------------------

  Future<void> declineJob() async {
    if (state.isLoading || !mounted) return;
    state = state.copyWith(status: JobActionStatus.loading, clearError: true);
    try {
      await _ref.read(firestoreServiceProvider).cancelRequest(_jobId);
      if (!mounted) return;
      state = state.copyWith(status: JobActionStatus.success);
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) state = const JobActionState();
    } catch (e) {
      _logError('declineJob', e);
      _handleError(e.toString());
    }
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  void clearError() {
    state = const JobActionState();
  }

  void _handleError(String message) {
    if (!mounted) return;
    state = state.copyWith(
      status:       JobActionStatus.error,
      errorMessage: message,
    );
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted && state.hasError) state = const JobActionState();
    });
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[JobActionController] ERROR in $method ($jobId): $error');
    }
  }

  String get jobId => _jobId;
}

// ============================================================================
// PROVIDER
// ============================================================================

final jobActionControllerProvider = StateNotifierProvider.autoDispose
    .family<JobActionController, JobActionState, String>(
  (ref, jobId) => JobActionController(
    ref.read(workerBidServiceProvider),
    ref,
    jobId,
  ),
);
