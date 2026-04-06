// lib/providers/bid_management_controller.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/worker_bid_service.dart';
import 'core_providers.dart';

// ============================================================================
// STATE
// ============================================================================

class BidManagementState {
  final bool isWithdrawing;
  final String? errorMessage;

  const BidManagementState({
    this.isWithdrawing = false,
    this.errorMessage,
  });

  BidManagementState copyWith({
    bool? isWithdrawing,
    String? errorMessage,
    bool clearError = false,
  }) {
    return BidManagementState(
      isWithdrawing: isWithdrawing ?? this.isWithdrawing,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

/// Owns the withdraw lifecycle for a single bid card, keyed on the bid ID.
///
/// A family provider means each card in the list gets its own isolated
/// loading state — withdrawing bid A never freezes the UI for bid B.
class BidManagementController extends StateNotifier<BidManagementState> {
  final WorkerBidService _bidService;

  BidManagementController(this._bidService)
      : super(const BidManagementState());

  Future<void> withdrawBid({
    required String bidId,
    required String requestId,
  }) async {
    if (state.isWithdrawing) return;
    if (!mounted) return;

    state = state.copyWith(isWithdrawing: true, clearError: true);
    try {
      await _bidService.withdrawBid(bidId: bidId, requestId: requestId);
      // Success: stream update from Firestore will remove the card from the
      // list automatically — no explicit success state needed here.
      if (!mounted) return;
      state = state.copyWith(isWithdrawing: false);
    } on WorkerBidServiceException catch (e) {
      _handleError(e.message);
    } catch (e) {
      _logError('withdrawBid', e);
      _handleError(e.toString());
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void _handleError(String message) {
    if (!mounted) return;
    state = state.copyWith(isWithdrawing: false, errorMessage: message);
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[BidManagementController] ERROR in $method: $error');
    }
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final bidManagementControllerProvider = StateNotifierProvider.autoDispose
    .family<BidManagementController, BidManagementState, String>(
  (ref, bidId) =>
      BidManagementController(ref.read(workerBidServiceProvider)),
);
