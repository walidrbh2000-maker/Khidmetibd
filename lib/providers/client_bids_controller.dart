// lib/providers/client_bids_controller.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/worker_bid_model.dart';
import '../services/worker_bid_service.dart';
import 'core_providers.dart';

// ============================================================================
// STATE
// ============================================================================

class ClientBidsState {
  final bool isAccepting;
  final String? acceptingBidId;
  final String? errorMessage;
  final bool success;

  const ClientBidsState({
    this.isAccepting = false,
    this.acceptingBidId,
    this.errorMessage,
    this.success = false,
  });

  ClientBidsState copyWith({
    bool? isAccepting,
    String? acceptingBidId,
    String? errorMessage,
    bool? success,
    bool clearError = false,
    bool clearAccepting = false,
  }) {
    return ClientBidsState(
      isAccepting: clearAccepting ? false : (isAccepting ?? this.isAccepting),
      acceptingBidId: clearAccepting
          ? null
          : (acceptingBidId ?? this.acceptingBidId),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      success: success ?? this.success,
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class ClientBidsController extends StateNotifier<ClientBidsState> {
  final WorkerBidService _bidService;

  ClientBidsController(this._bidService) : super(const ClientBidsState());

  Future<void> acceptBid({
    required String requestId,
    required WorkerBidModel bid,
  }) async {
    if (state.isAccepting) return;
    if (!mounted) return;

    state = state.copyWith(
      isAccepting: true,
      acceptingBidId: bid.id,
      clearError: true,
    );

    try {
      await _bidService.acceptBid(requestId: requestId, bid: bid);
      if (!mounted) return;
      state = state.copyWith(
        clearAccepting: true,
        success: true,
      );
    } on WorkerBidServiceException catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        clearAccepting: true,
        errorMessage: e.message,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        clearAccepting: true,
        errorMessage: e.toString(),
      );
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void resetSuccess() {
    state = state.copyWith(success: false);
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final clientBidsControllerProvider = StateNotifierProvider.autoDispose
    .family<ClientBidsController, ClientBidsState, String>(
  (ref, requestId) =>
      ClientBidsController(ref.read(workerBidServiceProvider)),
);
