// lib/services/worker_bid_service.dart
//
// SECURITY FIX (Critical — withdrawBid):
//   withdrawBid() previously read the bid to find workerId but NEVER verified
//   the caller was that worker. Any authenticated user who knew a bidId could
//   withdraw another worker's bid.
//
//   Fix: fetch the bid FIRST, verify bid.workerId == currentUid, then withdraw.
//   If the check fails, throw WorkerBidServiceException('AUTH_MISMATCH').
//
// SECURITY FIX (Warning — bid message length):
//   submitBid accepted message with no length cap. A malicious worker could
//   submit a 1 MB string causing UI render issues or Firestore document size
//   violations (1 MB document limit).
//
//   Fix: enforce _maxMessageLength = 500 chars.
//
// B1 FIX (Critical — withdrawBid try/catch):
//   The Firestore read + downstream calls in withdrawBid() had no try/catch.
//   A network error would silently propagate to callers with no error state set.
//   Fix: wrap from the auth-check forward in try/catch; rethrow as
//   WorkerBidServiceException like submitBid() does.
//
// ALGO FIX (A2 — streamBidsForRequest composite sort):
//   Previous sort ranked bids by price alone, then rating as a tiebreaker.
//   This caused a 1★ worker offering the lowest price to appear first, giving
//   clients a misleading "best bid" that was actually the worst worker quality.
//
//   Fix: composite score — normalised price saving (40%) + normalised rating
//   (60%), sorted descending. A worker 10% cheaper but 2★ lower will not
//   displace a well-rated worker. Weights can be tuned from user data.
//
//   Score formula:
//     bidScore = 0.40 × (1 - price/maxPrice) + 0.60 × (rating/5.0)
//
//   When maxPrice == minPrice (all bids equal), the price component collapses
//   to 0 for all bids and ranking is driven entirely by rating — correct.
//
// ALGO FIX (submitBid — workerJobsCompleted field):
//   workerJobsCompleted was populated from worker.ratingCount instead of
//   worker.jobsCompleted. ratingCount is the number of ratings received, NOT
//   the number of jobs completed — these diverge when clients don't always
//   leave a rating. A worker with 200 completed jobs but only 40 ratings would
//   appear to clients as having completed 40 jobs — understating experience.
//   Fix: use worker.jobsCompleted.
//
// [LOGIC-APPLY FIX] submitBid — own-request guard:
//   A worker could submit a bid on a request they created themselves (a user
//   who registered as both a client and a worker using the same account).
//   This poisons the bid list with a self-referential entry and could let a
//   malicious actor game the bidding system.
//
//   Fix: inside the transaction, compare reqData['userId'] with worker.id.
//   If they match, throw WorkerBidServiceException with code OWN_REQUEST.
//   This check runs inside the atomic transaction so it cannot be raced.
//
// [AUTO FIX] acceptBid, startJob, completeJob, submitClientRating:
//   These methods had no try/catch, so network errors and FirestoreService
//   exceptions surfaced as untyped exceptions at the controller layer.
//   Fix: each method now wraps its Firestore call in the same
//   try/on WorkerBidServiceException/catch pattern used by submitBid().

import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/service_request_enhanced_model.dart';
import '../models/worker_bid_model.dart';
import '../models/worker_model.dart';
import '../models/message_enums.dart';
import '../utils/constants.dart';
import 'firestore_service.dart';

/// High-level service for the Hybrid Bid Model.
/// Wraps FirestoreService with business-logic validation and worker data
/// enrichment so controllers stay thin.
class WorkerBidService {
  final FirestoreService _firestore;
  bool _isDisposed = false;

  static const String _pendingBidMarkersCollection = 'pending_bid_markers';

  // SECURITY FIX: maximum allowed bid message length.
  // Prevents 1 MB strings from hitting Firestore's 1 MB document limit.
  static const int _maxMessageLength = 500;

  // ALGO FIX (A2): composite sort weights for bid ranking.
  // wPrice: lower price is better — contributes (1 - normalizedPrice).
  // wRating: higher rating is better — contributes (rating / 5.0).
  // Tune after collecting sufficient client selection data.
  static const double _bidSortWeightPrice  = 0.40;
  static const double _bidSortWeightRating = 0.60;

  WorkerBidService(this._firestore);

  bool get isDisposed => _isDisposed;

  // =========================================================================
  // BROWSING — available requests for a worker
  // =========================================================================

  Stream<List<ServiceRequestEnhancedModel>> streamAvailableRequests({
    required int wilayaCode,
    required String serviceType,
  }) {
    _ensureNotDisposed();
    return _firestore.streamAvailableRequests(
      wilayaCode: wilayaCode,
      serviceType: serviceType,
    );
  }

  Stream<List<ServiceRequestEnhancedModel>> streamWorkerActiveJobs(
      String workerId) {
    _ensureNotDisposed();
    return _firestore.streamWorkerActiveJobs(workerId);
  }

  Stream<List<WorkerBidModel>> streamWorkerBids(String workerId) {
    _ensureNotDisposed();
    return _firestore.streamWorkerBids(workerId);
  }

  // =========================================================================
  // BID SUBMISSION
  // =========================================================================

  /// FIX (Security): verify caller identity before submitting.
  /// FIX (Critical): status check supports both .name and legacy .toString()
  ///   formats for backward compatibility with existing Firestore documents.
  /// FIX (Critical): status write uses .name ('awaitingSelection') to match
  ///   what ServiceRequestEnhancedModel.toMap() writes.
  /// FIX (Warning): message length capped at _maxMessageLength = 500 chars.
  /// ALGO FIX (submitBid): workerJobsCompleted now uses worker.jobsCompleted
  ///   (not worker.ratingCount — ratings ≠ completed jobs when clients skip
  ///   leaving a review).
  /// [LOGIC-APPLY FIX] own-request guard: prevents a worker from bidding on
  ///   a request they created themselves. Check runs inside the transaction.
  Future<WorkerBidModel> submitBid({
    required String requestId,
    required WorkerModel worker,
    required double proposedPrice,
    required int estimatedMinutes,
    required DateTime availableFrom,
    String? message,
  }) async {
    _ensureNotDisposed();

    // FIX: Verify the caller is actually the worker they claim to be.
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null || currentUid != worker.id) {
      throw WorkerBidServiceException(
        'Cannot submit bid: authenticated user does not match worker identity',
        code: 'AUTH_MISMATCH',
      );
    }

    if (proposedPrice <= 0) {
      throw WorkerBidServiceException(
        'Proposed price must be greater than 0',
        code: 'INVALID_PRICE',
      );
    }
    if (estimatedMinutes <= 0) {
      throw WorkerBidServiceException(
        'Estimated duration must be greater than 0',
        code: 'INVALID_DURATION',
      );
    }

    // FIX: Sanitize and cap message length to prevent oversized Firestore docs.
    String? sanitizedMessage;
    if (message != null && message.trim().isNotEmpty) {
      final trimmed = message.trim();
      sanitizedMessage = trimmed.substring(0, min(trimmed.length, _maxMessageLength));
    }

    final bidId = const Uuid().v4();
    final deadline = DateTime.now().add(
      const Duration(minutes: AppConstants.biddingDeadlineMinutes),
    );

    final bid = WorkerBidModel(
      id: bidId,
      serviceRequestId: requestId,
      workerId: worker.id,
      workerName: worker.name,
      workerAverageRating: worker.averageRating,
      // ALGO FIX: use jobsCompleted, not ratingCount.
      // ratingCount = number of ratings received (clients may skip rating).
      // jobsCompleted = actual number of jobs finished — the correct field.
      workerJobsCompleted: worker.jobsCompleted,
      workerProfileImageUrl: worker.profileImageUrl,
      proposedPrice: proposedPrice,
      estimatedMinutes: estimatedMinutes,
      availableFrom: availableFrom,
      message: sanitizedMessage,
      status: BidStatus.pending,
      createdAt: DateTime.now(),
      expiresAt: deadline,
    );

    final markerDocId = '${worker.id}_$requestId';
    final markerRef = _firestore.firestore
        .collection(_pendingBidMarkersCollection)
        .doc(markerDocId);
    final bidRef = _firestore.firestore
        .collection(FirestoreService.workerBidsCollection)
        .doc(bidId);
    final requestRef = _firestore.firestore
        .collection(FirestoreService.serviceRequestsCollection)
        .doc(requestId);

    try {
      await _firestore.firestore.runTransaction((tx) async {
        final markerSnap = await tx.get(markerRef);
        if (markerSnap.exists) {
          throw WorkerBidServiceException(
            'You already have a pending bid on this request',
            code: 'DUPLICATE_BID',
          );
        }

        final reqSnap = await tx.get(requestRef);
        if (!reqSnap.exists || reqSnap.data() == null) {
          throw WorkerBidServiceException(
            'Request not found: $requestId',
            code: 'REQUEST_NOT_FOUND',
          );
        }

        final reqData = reqSnap.data()!;

        // [LOGIC-APPLY FIX] own-request guard — inside the transaction so
        // it cannot be raced. Compares the request creator's userId with the
        // bidding worker's id. A dual-role account (user who is also a worker)
        // must not be allowed to bid on their own service request.
        final requestUserId = reqData['userId'] as String?;
        if (requestUserId != null && requestUserId == worker.id) {
          throw WorkerBidServiceException(
            'Cannot submit a bid on your own service request',
            code: 'OWN_REQUEST',
          );
        }

        final statusStr = reqData['status'] as String? ?? '';

        // Accept both .name ('open', 'awaitingSelection') and legacy
        // .toString() ('ServiceStatus.open', etc.) formats.
        final isOpen =
            statusStr == ServiceStatus.open.name ||
            statusStr == ServiceStatus.awaitingSelection.name ||
            statusStr == ServiceStatus.open.toString() ||
            statusStr == ServiceStatus.awaitingSelection.toString();

        if (!isOpen) {
          throw WorkerBidServiceException(
            'Request is no longer accepting bids',
            code: 'REQUEST_CLOSED',
          );
        }

        tx.set(markerRef, {
          'workerId': worker.id,
          'requestId': requestId,
          'bidId': bidId,
          'createdAt': Timestamp.now(),
        });
        tx.set(bidRef, bid.toMap());
        tx.update(requestRef, {
          'bidCount': FieldValue.increment(1),
          'status': ServiceStatus.awaitingSelection.name,
        });
      }).timeout(const Duration(seconds: 15));

      _logInfo('Bid submitted atomically: $bidId by ${worker.id} on $requestId');
      return bid;
    } on WorkerBidServiceException {
      rethrow;
    } catch (e) {
      _logError('submitBid', e);
      throw WorkerBidServiceException(
        'Failed to submit bid',
        code: 'SUBMIT_BID_FAILED',
        originalError: e,
      );
    }
  }

  // =========================================================================
  // BID ACCEPTANCE (client action)
  // =========================================================================

  /// [AUTO FIX] Wrapped in try/catch matching the submitBid() pattern.
  /// Previously unhandled exceptions from acceptBidTransaction() would
  /// propagate as untyped errors to the ClientBidsController.
  Future<void> acceptBid({
    required String requestId,
    required WorkerBidModel bid,
  }) async {
    _ensureNotDisposed();

    try {
      await _firestore.acceptBidTransaction(
        requestId: requestId,
        bidId: bid.id,
        workerId: bid.workerId,
        workerName: bid.workerName,
        agreedPrice: bid.proposedPrice,
      );

      await _deleteMarker(bid.workerId, requestId);

      _logInfo('Bid accepted: ${bid.id} — worker ${bid.workerId} on $requestId');
    } on WorkerBidServiceException {
      rethrow;
    } catch (e) {
      _logError('acceptBid', e);
      throw WorkerBidServiceException(
        'Failed to accept bid',
        code: 'ACCEPT_BID_FAILED',
        originalError: e,
      );
    }
  }

  // =========================================================================
  // BID WITHDRAWAL (worker action)
  // =========================================================================

  /// SECURITY FIX: verify the caller owns this bid before withdrawing.
  ///
  /// Previously: any authenticated user who knew a bidId could call this
  /// method and withdraw another worker's bid — there was no auth check.
  ///
  /// B1 FIX: wrap all operations from uid-check forward in try/catch and
  /// rethrow as WorkerBidServiceException, consistent with submitBid().
  ///
  /// Fix:
  ///   1. Verify currentUid is non-null (UNAUTHENTICATED guard).
  ///   2. Fetch the bid document inside try/catch.
  ///   3. Compare bid.workerId with currentUid (AUTH_MISMATCH guard).
  ///   4. Only then call _firestore.withdrawBid() and _deleteMarker().
  Future<void> withdrawBid({
    required String bidId,
    required String requestId,
  }) async {
    _ensureNotDisposed();

    // SECURITY FIX: verify the caller is the bid owner.
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      throw WorkerBidServiceException(
        'Not authenticated',
        code: 'UNAUTHENTICATED',
      );
    }

    // B1 FIX: wrap Firestore read + downstream calls in try/catch so that
    // network errors surface as typed exceptions rather than silently
    // propagating to callers.
    try {
      // Fetch bid and verify ownership BEFORE withdrawing.
      final snap = await _firestore.firestore
          .collection(FirestoreService.workerBidsCollection)
          .doc(bidId)
          .get()
          .timeout(const Duration(seconds: 10));

      if (!snap.exists || snap.data() == null) {
        throw WorkerBidServiceException(
          'Bid not found: $bidId',
          code: 'BID_NOT_FOUND',
        );
      }

      final bidData = snap.data()!;
      final bidOwnerId = bidData['workerId'] as String?;

      if (bidOwnerId == null || bidOwnerId != currentUid) {
        throw WorkerBidServiceException(
          'Cannot withdraw bid owned by another worker',
          code: 'AUTH_MISMATCH',
        );
      }

      // Identity verified — safe to proceed.
      await _firestore.withdrawBid(bidId: bidId, requestId: requestId);
      await _deleteMarker(currentUid, requestId);

      _logInfo('Bid withdrawn: $bidId by $currentUid');
    } on WorkerBidServiceException {
      rethrow;
    } catch (e) {
      _logError('withdrawBid', e);
      throw WorkerBidServiceException(
        'Failed to withdraw bid',
        code: 'WITHDRAW_BID_FAILED',
        originalError: e,
      );
    }
  }

  // =========================================================================
  // JOB LIFECYCLE
  // =========================================================================

  /// [AUTO FIX] Wrapped in try/catch matching the submitBid() pattern.
  /// Previously unhandled exceptions from _firestore.startJob() would
  /// propagate as untyped errors to JobActionController / MissionController.
  Future<void> startJob(String requestId) async {
    _ensureNotDisposed();
    try {
      await _firestore.startJob(requestId);
      _logInfo('Job started: $requestId');
    } on WorkerBidServiceException {
      rethrow;
    } catch (e) {
      _logError('startJob', e);
      throw WorkerBidServiceException(
        'Failed to start job',
        code: 'START_JOB_FAILED',
        originalError: e,
      );
    }
  }

  /// [AUTO FIX] Wrapped in try/catch matching the submitBid() pattern.
  /// Previously unhandled exceptions from _firestore.completeJob() would
  /// propagate as untyped errors to JobActionController / MissionController.
  Future<void> completeJob({
    required String requestId,
    String? workerNotes,
    double? finalPrice,
  }) async {
    _ensureNotDisposed();
    try {
      await _firestore.completeJob(
        requestId: requestId,
        workerNotes: workerNotes,
        finalPrice: finalPrice,
      );
      _logInfo('Job completed: $requestId');
    } on WorkerBidServiceException {
      rethrow;
    } catch (e) {
      _logError('completeJob', e);
      throw WorkerBidServiceException(
        'Failed to complete job',
        code: 'COMPLETE_JOB_FAILED',
        originalError: e,
      );
    }
  }

  // =========================================================================
  // BIDS STREAM — client side
  // =========================================================================

  /// FIX (A2): replaced price-only sort with a composite price+rating score.
  ///
  /// OLD: sorted by proposedPrice ASC, then rating DESC as tiebreaker.
  ///   Problem: a 1★ worker with the lowest price always topped the list,
  ///   misleading clients into thinking cheapest = best.
  ///
  /// NEW: composite score — weighted price saving + quality signal.
  ///   bidScore = wPrice × (1 − price/maxPrice) + wRating × (rating/5.0)
  ///
  ///   • wPrice  = 0.40 — price saving (inverted so lower price → higher score)
  ///   • wRating = 0.60 — quality signal (Bayesian rating from worker profile)
  ///
  ///   When all bids have the same price, the price component is 0 for all
  ///   and ranking collapses to pure rating — correct fallback behaviour.
  ///
  ///   Tune [_bidSortWeightPrice] / [_bidSortWeightRating] after collecting
  ///   client selection data to reflect what clients actually care about.
  Stream<List<WorkerBidModel>> streamBidsForRequest(String requestId) {
    _ensureNotDisposed();
    return _firestore.streamBidsForRequest(requestId).map(
      (bids) {
        if (bids.isEmpty) return bids;

        final sorted = List<WorkerBidModel>.from(bids);

        // Compute price range for normalization.
        // Guard against division by zero when all prices are equal.
        final maxPrice = sorted.map((b) => b.proposedPrice).reduce(max);
        final minPrice = sorted.map((b) => b.proposedPrice).reduce(min);
        final priceRange = maxPrice - minPrice;

        sorted.sort((a, b) {
          // Normalised price saving: 0 (most expensive) → 1 (cheapest).
          // When priceRange == 0 both scores are 0 — pure rating ranking.
          final aPriceSaving = priceRange > 0
              ? (maxPrice - a.proposedPrice) / priceRange
              : 0.0;
          final bPriceSaving = priceRange > 0
              ? (maxPrice - b.proposedPrice) / priceRange
              : 0.0;

          // Normalised rating: 0 → 1.
          final aRatingScore = (a.workerAverageRating / 5.0).clamp(0.0, 1.0);
          final bRatingScore = (b.workerAverageRating / 5.0).clamp(0.0, 1.0);

          final scoreA = _bidSortWeightPrice  * aPriceSaving
                       + _bidSortWeightRating * aRatingScore;
          final scoreB = _bidSortWeightPrice  * bPriceSaving
                       + _bidSortWeightRating * bRatingScore;

          // Descending — higher composite score first.
          return scoreB.compareTo(scoreA);
        });

        return sorted;
      },
    );
  }

  // =========================================================================
  // RATING
  // =========================================================================

  /// [AUTO FIX] Wrapped in try/catch matching the submitBid() pattern.
  /// Previously unhandled exceptions from _firestore.submitClientRating()
  /// would propagate as untyped errors to RatingController.
  Future<void> submitClientRating({
    required String requestId,
    required int stars,
    String? comment,
  }) async {
    _ensureNotDisposed();
    try {
      await _firestore.submitClientRating(
        requestId: requestId,
        stars: stars,
        comment: comment,
      );
    } on WorkerBidServiceException {
      rethrow;
    } catch (e) {
      _logError('submitClientRating', e);
      throw WorkerBidServiceException(
        'Failed to submit rating',
        code: 'SUBMIT_RATING_FAILED',
        originalError: e,
      );
    }
  }

  // =========================================================================
  // HELPERS
  // =========================================================================

  Future<void> _deleteMarker(String workerId, String requestId) async {
    try {
      final markerDocId = '${workerId}_$requestId';
      await _firestore.firestore
          .collection(_pendingBidMarkersCollection)
          .doc(markerDocId)
          .delete()
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      _logWarning('Could not delete bid marker for $workerId/$requestId: $e');
    }
  }

  void dispose() {
    _isDisposed = true;
    _logInfo('WorkerBidService disposed');
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw WorkerBidServiceException(
        'WorkerBidService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[WorkerBidService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[WorkerBidService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) debugPrint('[WorkerBidService] ERROR in $method: $error');
  }
}

class WorkerBidServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  WorkerBidServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'WorkerBidServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}
