// lib/providers/cancel_request_controller.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core_providers.dart';

// ============================================================================
// STATE
// ============================================================================

class CancelRequestState {
  final bool    isLoading;
  final String? errorKey;
  final bool    success;

  const CancelRequestState({
    this.isLoading = false,
    this.errorKey,
    this.success   = false,
  });

  CancelRequestState copyWith({
    bool?    isLoading,
    String?  errorKey,
    bool?    success,
    bool     clearError = false,
  }) {
    return CancelRequestState(
      isLoading: isLoading ?? this.isLoading,
      errorKey:  clearError ? null : (errorKey ?? this.errorKey),
      success:   success   ?? this.success,
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class CancelRequestController extends StateNotifier<CancelRequestState> {
  final Ref    _ref;
  final String _requestId;

  CancelRequestController(this._ref, {required String requestId})
      : _requestId = requestId,
        super(const CancelRequestState());

  Future<void> cancel() async {
    if (state.isLoading || !mounted) return;

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      await _ref.read(firestoreServiceProvider).cancelRequest(_requestId);
      if (!mounted) return;
      state = state.copyWith(isLoading: false, success: true);
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, errorKey: 'errors.generic');
    }
  }

  void clearError() => state = state.copyWith(clearError: true);
}

// ============================================================================
// PROVIDER
// ============================================================================

final cancelRequestControllerProvider = StateNotifierProvider.autoDispose
    .family<CancelRequestController, CancelRequestState, String>(
  (ref, requestId) => CancelRequestController(ref, requestId: requestId),
);
