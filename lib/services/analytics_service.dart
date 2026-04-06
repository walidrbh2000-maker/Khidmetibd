// lib/services/analytics_service.dart

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

class AnalyticsService {
  final FirebaseAnalytics _analytics;

  AnalyticsService({FirebaseAnalytics? analytics})
      : _analytics = analytics ?? FirebaseAnalytics.instance;

  // ============================================================================
  // AUTH EVENTS
  // FIX (Marketplace P1 + Backend Audit): auth funnel events were entirely
  // absent. Without these, it is impossible to measure sign-in success rates,
  // social provider adoption, registration abandonment, or role distribution.
  // ============================================================================

  /// Fired when a user successfully signs in by any method.
  /// [provider]: 'email' | 'google' | 'facebook' | 'apple'
  void logUserSignedIn({required String provider}) {
    _fire('user_signed_in', {'provider': provider});
  }

  /// Fired when a user completes registration and their role is cached.
  /// [provider]: 'email' | 'google' | 'facebook' | 'apple'
  /// [role]: 'client' | 'worker'
  void logUserRegistered({
    required String provider,
    required String role,
  }) {
    _fire('user_registered', {'provider': provider, 'role': role});
  }

  // FIX (Settings Audit P1): SettingsNotifier was calling
  // FirebaseAnalytics.instance.logEvent directly, bypassing the service layer
  // and making the notifier untestable. These two methods replace those calls.

  /// Fired when a user successfully signs out.
  /// [accountType]: 'client' | 'worker'
  void logUserSignedOut({required String accountType}) {
    _fire('user_signed_out', {'account_type': accountType});
  }

  /// Fired when a user permanently deletes their account.
  /// [accountType]: 'client' | 'worker'
  void logUserDeletedAccount({required String accountType}) {
    _fire('user_deleted_account', {'account_type': accountType});
  }

  // ============================================================================
  // SERVICE REQUEST EVENTS
  // ============================================================================

  /// Fired when a client successfully creates a new service request.
  void logRequestCreated({
    required String requestId,
    required String serviceType,
    required String priority,
    required int    mediaCount,
    required bool   isEmergency,
    required int    wilayaCode,
  }) {
    _fire('request_created', {
      'request_id':   requestId,
      'service_type': serviceType,
      'priority':     priority,
      'media_count':  mediaCount,
      'is_emergency': isEmergency,
      'wilaya_code':  wilayaCode,
    });
  }

  /// Fired when a client cancels a request.
  void logRequestCancelled({
    required String requestId,
    required String previousStatus,
  }) {
    _fire('request_cancelled', {
      'request_id':      requestId,
      'previous_status': previousStatus,
    });
  }

  // ============================================================================
  // BID EVENTS
  // ============================================================================

  /// Fired when a worker submits a bid on a request.
  void logBidSubmitted({
    required String bidId,
    required String requestId,
    required String workerId,
    required double proposedPrice,
    required int    estimatedMinutes,
  }) {
    _fire('bid_submitted', {
      'bid_id':            bidId,
      'request_id':        requestId,
      'worker_id':         workerId,
      'proposed_price':    proposedPrice.round(),
      'estimated_minutes': estimatedMinutes,
    });
  }

  /// Fired when a client selects a worker (accepts a bid).
  void logBidAccepted({
    required String bidId,
    required String requestId,
    required String workerId,
    required double agreedPrice,
    required int    totalBidsOnRequest,
  }) {
    _fire('bid_accepted', {
      'bid_id':      bidId,
      'request_id':  requestId,
      'worker_id':   workerId,
      'agreed_price': agreedPrice.round(),
      'total_bids':  totalBidsOnRequest,
    });
  }

  /// Fired when a worker withdraws their own bid.
  void logBidWithdrawn({
    required String bidId,
    required String requestId,
    required String workerId,
  }) {
    _fire('bid_withdrawn', {
      'bid_id':     bidId,
      'request_id': requestId,
      'worker_id':  workerId,
    });
  }

  // ============================================================================
  // JOB LIFECYCLE EVENTS
  // ============================================================================

  /// Fired when a worker starts a job (confirms on-site arrival).
  void logJobStarted({
    required String requestId,
    required String workerId,
  }) {
    _fire('job_started', {
      'request_id': requestId,
      'worker_id':  workerId,
    });
  }

  /// Fired when a worker marks a job as completed.
  void logJobCompleted({
    required String requestId,
    required String workerId,
    required bool   hasFinalPrice,
    required bool   hasNotes,
  }) {
    _fire('job_completed', {
      'request_id':     requestId,
      'worker_id':      workerId,
      'has_final_price': hasFinalPrice,
      'has_notes':       hasNotes,
    });
  }

  // ============================================================================
  // RATING EVENT
  // ============================================================================

  /// Fired when a client submits a star rating after job completion.
  void logRatingSubmitted({
    required String requestId,
    required String workerId,
    required int    stars,
    required bool   hasComment,
  }) {
    _fire('rating_submitted', {
      'request_id':  requestId,
      'worker_id':   workerId,
      'stars':       stars,
      'has_comment': hasComment,
    });
  }

  // ============================================================================
  // PROFILE EVENTS
  // ============================================================================

  /// Fired when a user successfully updates their profile.
  /// [accountType]: 'client' | 'worker'
  /// [imageChanged]: whether a new profile photo was uploaded.
  void logProfileUpdated({
    required String accountType,
    required bool   imageChanged,
  }) {
    _fire('profile_updated', {
      'account_type':  accountType,
      'image_changed': imageChanged,
    });
  }

  // ============================================================================
  // BROWSE / DISCOVERY EVENTS
  // ============================================================================

  /// Fired when a worker applies a filter on the Browse tab.
  void logBrowseFilterApplied({
    required String filter,
    required int    resultsCount,
  }) {
    _fire('browse_filter_applied', {
      'filter':        filter,
      'results_count': resultsCount,
    });
  }

  /// Fired once when the Browse tab becomes visible to a worker.
  void logWorkerBrowseScreenViewed({
    required int availableRequestsCount,
  }) {
    _fire('worker_browse_viewed', {
      'available_requests': availableRequestsCount,
    });
  }

  // ============================================================================
  // FIRE-AND-FORGET HELPER
  // ============================================================================

  /// Logs a custom Firebase Analytics event.
  /// Never throws — analytics failures are non-fatal.
  void _fire(String name, Map<String, Object> parameters) {
    _analytics
        .logEvent(name: name, parameters: parameters)
        .catchError((Object e) {
      if (kDebugMode) {
        debugPrint('[AnalyticsService] WARNING: failed to log "$name": $e');
      }
    });
  }
}
