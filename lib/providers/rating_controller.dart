// lib/providers/rating_controller.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/worker_bid_service.dart';
import 'core_providers.dart';

// ============================================================================
// STATE
// ============================================================================

class RatingState {
  final int    stars;
  final bool   isSubmitting;
  final String? errorKey;
  final bool   success;

  const RatingState({
    this.stars        = 0,
    this.isSubmitting = false,
    this.errorKey,
    this.success      = false,
  });

  bool get canSubmit => stars > 0 && !isSubmitting;

  RatingState copyWith({
    int?    stars,
    bool?   isSubmitting,
    String? errorKey,
    bool?   success,
    bool    clearError = false,
  }) {
    return RatingState(
      stars:        stars        ?? this.stars,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      errorKey:     clearError   ? null : (errorKey ?? this.errorKey),
      success:      success      ?? this.success,
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class RatingController extends StateNotifier<RatingState> {
  final Ref    _ref;
  final String _requestId;

  RatingController(this._ref, {required String requestId})
      : _requestId = requestId,
        super(const RatingState());

  void setStars(int stars) {
    if (stars < 1 || stars > 5) return;
    state = state.copyWith(stars: stars, clearError: true);
  }

  Future<void> submit({String? comment}) async {
    if (!state.canSubmit || !mounted) return;

    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      await _ref.read(workerBidServiceProvider).submitClientRating(
            requestId: _requestId,
            stars:     state.stars,
            comment:   comment,
          );
      if (!mounted) return;
      state = state.copyWith(isSubmitting: false, success: true);
    } on WorkerBidServiceException catch (e) {
      if (!mounted) return;
      state = state.copyWith(isSubmitting: false, errorKey: e.message);
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(isSubmitting: false, errorKey: 'errors.generic');
    }
  }

  void resetSuccess() => state = state.copyWith(success: false);
}

// ============================================================================
// PROVIDER
// ============================================================================

final ratingControllerProvider = StateNotifierProvider.autoDispose
    .family<RatingController, RatingState, String>(
  (ref, requestId) => RatingController(ref, requestId: requestId),
);
