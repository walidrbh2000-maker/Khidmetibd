// lib/models/service_request_enhanced_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'message_enums.dart';

class ServiceRequestEnhancedModel extends Equatable {
  // ── Core identity ──────────────────────────────────────────────────────────
  final String id;
  final String userId;
  final String userName;
  final String userPhone;

  // ── Service details ────────────────────────────────────────────────────────
  final String serviceType;
  final String title;
  final String description;
  final DateTime scheduledDate;
  final TimeOfDay scheduledTime;
  final ServicePriority priority;
  final List<String> mediaUrls;

  // ── Status ─────────────────────────────────────────────────────────────────
  final ServiceStatus status;

  // ── Location ───────────────────────────────────────────────────────────────
  final double userLatitude;
  final double userLongitude;
  final String userAddress;

  // ── Geo grid ───────────────────────────────────────────────────────────────
  final String? cellId;
  final int? wilayaCode;
  final String? geoHash;
  final DateTime? lastCellUpdate;

  // ── Hybrid bid model — NEW FIELDS ──────────────────────────────────────────

  /// Number of bids submitted — incremented atomically on bid creation
  final int bidCount;

  /// Bidding deadline — Cloud Function sets expiry; null = no deadline set yet
  final DateTime? biddingDeadlineAt;

  /// Firestore ID of the accepted WorkerBidModel
  final String? selectedBidId;

  /// Optional client-provided budget range (DZD)
  final double? budgetMin;
  final double? budgetMax;

  // ── Selected worker (denormalized for fast display) ────────────────────────
  final String? workerId;
  final String? workerName;

  /// Price agreed upon at bid selection
  final double? agreedPrice;

  // ── Timestamps ─────────────────────────────────────────────────────────────
  final DateTime createdAt;
  final DateTime? bidSelectedAt;
  final DateTime? acceptedAt;
  final DateTime? completedAt;

  // ── Outcome ────────────────────────────────────────────────────────────────
  final String? workerNotes;
  final double? finalPrice;
  final double? estimatedPrice;
  final int? estimatedDuration;

  // ── Rating (client rates worker) ───────────────────────────────────────────
  /// Stars 1–5; null means not yet rated
  final int? clientRating;
  final String? reviewComment;

  // ── Legacy alias — kept for backward compatibility with existing widgets ───
  int? get rating => clientRating;

  const ServiceRequestEnhancedModel({
    required this.id,
    required this.userId,
    required this.userName,
    required this.userPhone,
    required this.serviceType,
    required this.title,
    required this.description,
    required this.scheduledDate,
    required this.scheduledTime,
    required this.priority,
    required this.status,
    required this.userLatitude,
    required this.userLongitude,
    required this.userAddress,
    required this.mediaUrls,
    this.bidCount = 0,
    this.biddingDeadlineAt,
    this.selectedBidId,
    this.budgetMin,
    this.budgetMax,
    this.workerId,
    this.workerName,
    this.agreedPrice,
    required this.createdAt,
    this.bidSelectedAt,
    this.acceptedAt,
    this.completedAt,
    this.workerNotes,
    this.finalPrice,
    this.estimatedPrice,
    this.estimatedDuration,
    this.clientRating,
    this.reviewComment,
    this.cellId,
    this.wilayaCode,
    this.geoHash,
    this.lastCellUpdate,
  });

  // FIX (§14): extracted as a static private method so it can be unit-tested
  // independently and is not captured as a local closure inside fromMap.
  // Supports both legacy '.toString()' format ('ServiceStatus.open') and new
  // '.name' format ('open') written by toMap() going forward.
  static ServiceStatus _parseStatus(dynamic raw) {
    final s = raw?.toString() ?? '';
    switch (s) {
      // New short format (.name) — written by toMap() going forward
      case 'open':              return ServiceStatus.open;
      case 'awaitingSelection': return ServiceStatus.awaitingSelection;
      case 'bidSelected':       return ServiceStatus.bidSelected;
      case 'inProgress':        return ServiceStatus.inProgress;
      case 'completed':         return ServiceStatus.completed;
      case 'cancelled':         return ServiceStatus.cancelled;
      case 'expired':           return ServiceStatus.expired;
      case 'pending':           return ServiceStatus.pending;
      case 'accepted':          return ServiceStatus.accepted;
      case 'declined':          return ServiceStatus.declined;
      // Legacy toString() format — kept for backward compat with existing docs
      case 'ServiceStatus.open':              return ServiceStatus.open;
      case 'ServiceStatus.awaitingSelection': return ServiceStatus.awaitingSelection;
      case 'ServiceStatus.bidSelected':       return ServiceStatus.bidSelected;
      case 'ServiceStatus.inProgress':        return ServiceStatus.inProgress;
      case 'ServiceStatus.completed':         return ServiceStatus.completed;
      case 'ServiceStatus.cancelled':         return ServiceStatus.cancelled;
      case 'ServiceStatus.expired':           return ServiceStatus.expired;
      case 'ServiceStatus.pending':           return ServiceStatus.pending;
      case 'ServiceStatus.accepted':          return ServiceStatus.accepted;
      case 'ServiceStatus.declined':          return ServiceStatus.declined;
      default:                                return ServiceStatus.open;
    }
  }

  factory ServiceRequestEnhancedModel.fromMap(
      Map<String, dynamic> map, String id) {
    return ServiceRequestEnhancedModel(
      id: id,
      userId: map['userId'] as String? ?? '',
      userName: map['userName'] as String? ?? '',
      userPhone: map['userPhone'] as String? ?? '',
      serviceType: map['serviceType'] as String? ?? '',
      title: map['title'] as String? ?? '',
      description: map['description'] as String? ?? '',
      scheduledDate:
          (map['scheduledDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      scheduledTime: TimeOfDay(
        hour: map['scheduledHour'] as int? ?? 9,
        minute: map['scheduledMinute'] as int? ?? 0,
      ),
      priority: ServicePriority.values.firstWhere(
        (e) => e.name == map['priority'] || e.toString() == map['priority'],
        orElse: () => ServicePriority.normal,
      ),
      status: _parseStatus(map['status']),
      userLatitude: (map['userLatitude'] as num?)?.toDouble() ?? 0.0,
      userLongitude: (map['userLongitude'] as num?)?.toDouble() ?? 0.0,
      userAddress: map['userAddress'] as String? ?? '',
      mediaUrls: List<String>.from(map['mediaUrls'] as List? ?? []),
      bidCount: map['bidCount'] as int? ?? 0,
      biddingDeadlineAt: (map['biddingDeadlineAt'] as Timestamp?)?.toDate(),
      selectedBidId: map['selectedBidId'] as String?,
      budgetMin: (map['budgetMin'] as num?)?.toDouble(),
      budgetMax: (map['budgetMax'] as num?)?.toDouble(),
      workerId: map['workerId'] as String?,
      workerName: map['workerName'] as String?,
      agreedPrice: (map['agreedPrice'] as num?)?.toDouble(),
      createdAt:
          (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      bidSelectedAt: (map['bidSelectedAt'] as Timestamp?)?.toDate(),
      acceptedAt: (map['acceptedAt'] as Timestamp?)?.toDate(),
      completedAt: (map['completedAt'] as Timestamp?)?.toDate(),
      workerNotes: map['workerNotes'] as String?,
      finalPrice: (map['finalPrice'] as num?)?.toDouble(),
      estimatedPrice: (map['estimatedPrice'] as num?)?.toDouble(),
      estimatedDuration: map['estimatedDuration'] as int?,
      clientRating: map['clientRating'] as int? ?? map['rating'] as int?,
      reviewComment: map['reviewComment'] as String?,
      cellId: map['cellId'] as String?,
      wilayaCode: map['wilayaCode'] as int?,
      geoHash: map['geoHash'] as String?,
      lastCellUpdate: (map['lastCellUpdate'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'userName': userName,
      'userPhone': userPhone,
      'serviceType': serviceType,
      'title': title,
      'description': description,
      'scheduledDate': Timestamp.fromDate(scheduledDate),
      'scheduledHour': scheduledTime.hour,
      'scheduledMinute': scheduledTime.minute,
      'priority': priority.name,
      'status': status.name,
      'userLatitude': userLatitude,
      'userLongitude': userLongitude,
      'userAddress': userAddress,
      'mediaUrls': mediaUrls,
      'bidCount': bidCount,
      'biddingDeadlineAt': biddingDeadlineAt != null
          ? Timestamp.fromDate(biddingDeadlineAt!)
          : null,
      'selectedBidId': selectedBidId,
      'budgetMin': budgetMin,
      'budgetMax': budgetMax,
      'workerId': workerId,
      'workerName': workerName,
      'agreedPrice': agreedPrice,
      'createdAt': Timestamp.fromDate(createdAt),
      'bidSelectedAt':
          bidSelectedAt != null ? Timestamp.fromDate(bidSelectedAt!) : null,
      'acceptedAt':
          acceptedAt != null ? Timestamp.fromDate(acceptedAt!) : null,
      'completedAt':
          completedAt != null ? Timestamp.fromDate(completedAt!) : null,
      'workerNotes': workerNotes,
      'finalPrice': finalPrice,
      'estimatedPrice': estimatedPrice,
      'estimatedDuration': estimatedDuration,
      'clientRating': clientRating,
      'reviewComment': reviewComment,
      'cellId': cellId,
      'wilayaCode': wilayaCode,
      'geoHash': geoHash,
      'lastCellUpdate': lastCellUpdate != null
          ? Timestamp.fromDate(lastCellUpdate!)
          : null,
    };
  }

  ServiceRequestEnhancedModel copyWith({
    String? id,
    String? userId,
    String? userName,
    String? userPhone,
    String? serviceType,
    String? title,
    String? description,
    DateTime? scheduledDate,
    TimeOfDay? scheduledTime,
    ServicePriority? priority,
    ServiceStatus? status,
    double? userLatitude,
    double? userLongitude,
    String? userAddress,
    List<String>? mediaUrls,
    int? bidCount,
    DateTime? biddingDeadlineAt,
    String? selectedBidId,
    double? budgetMin,
    double? budgetMax,
    String? workerId,
    String? workerName,
    double? agreedPrice,
    DateTime? createdAt,
    DateTime? bidSelectedAt,
    DateTime? acceptedAt,
    DateTime? completedAt,
    String? workerNotes,
    double? finalPrice,
    double? estimatedPrice,
    int? estimatedDuration,
    int? clientRating,
    String? reviewComment,
    String? cellId,
    int? wilayaCode,
    String? geoHash,
    DateTime? lastCellUpdate,
  }) {
    return ServiceRequestEnhancedModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      userPhone: userPhone ?? this.userPhone,
      serviceType: serviceType ?? this.serviceType,
      title: title ?? this.title,
      description: description ?? this.description,
      scheduledDate: scheduledDate ?? this.scheduledDate,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      userLatitude: userLatitude ?? this.userLatitude,
      userLongitude: userLongitude ?? this.userLongitude,
      userAddress: userAddress ?? this.userAddress,
      mediaUrls: mediaUrls ?? this.mediaUrls,
      bidCount: bidCount ?? this.bidCount,
      biddingDeadlineAt: biddingDeadlineAt ?? this.biddingDeadlineAt,
      selectedBidId: selectedBidId ?? this.selectedBidId,
      budgetMin: budgetMin ?? this.budgetMin,
      budgetMax: budgetMax ?? this.budgetMax,
      workerId: workerId ?? this.workerId,
      workerName: workerName ?? this.workerName,
      agreedPrice: agreedPrice ?? this.agreedPrice,
      createdAt: createdAt ?? this.createdAt,
      bidSelectedAt: bidSelectedAt ?? this.bidSelectedAt,
      acceptedAt: acceptedAt ?? this.acceptedAt,
      completedAt: completedAt ?? this.completedAt,
      workerNotes: workerNotes ?? this.workerNotes,
      finalPrice: finalPrice ?? this.finalPrice,
      estimatedPrice: estimatedPrice ?? this.estimatedPrice,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      clientRating: clientRating ?? this.clientRating,
      reviewComment: reviewComment ?? this.reviewComment,
      cellId: cellId ?? this.cellId,
      wilayaCode: wilayaCode ?? this.wilayaCode,
      geoHash: geoHash ?? this.geoHash,
      lastCellUpdate: lastCellUpdate ?? this.lastCellUpdate,
    );
  }

  // ── Convenience getters ────────────────────────────────────────────────────

  bool get hasWorker => workerId != null && workerId!.isNotEmpty;

  bool get hasBids => bidCount > 0;

  bool get isRatedByClient => clientRating != null;

  /// True when deadline exists and has not yet passed
  bool get isBiddingOpen {
    if (biddingDeadlineAt == null) return true;
    return DateTime.now().isBefore(biddingDeadlineAt!);
  }

  Duration? get timeUntilDeadline {
    if (biddingDeadlineAt == null) return null;
    final remaining = biddingDeadlineAt!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // FIX (L10n P1): displayPrice previously appended the hardcoded string
  // 'DZD' directly — not localizable from the model layer (no BuildContext).
  //
  // Solution:
  //   • displayAmount  → formatted number only (e.g. '3 500' or '~2 000')
  //   • displayPrice   → kept as a @Deprecated alias so existing callers that
  //                      still reference it will see a warning but compile.
  //                      All UI call sites have been updated to use:
  //                        '${req.displayAmount} ${context.tr('common.currency')}'

  /// Formatted amount string WITHOUT currency suffix.
  /// Append `context.tr('common.currency')` in the UI layer.
  String? get displayAmount {
    if (agreedPrice != null) return agreedPrice!.toStringAsFixed(0);
    if (finalPrice != null)  return finalPrice!.toStringAsFixed(0);
    if (budgetMin != null && budgetMax != null) {
      return '${budgetMin!.toStringAsFixed(0)}–${budgetMax!.toStringAsFixed(0)}';
    }
    if (estimatedPrice != null) return '~${estimatedPrice!.toStringAsFixed(0)}';
    return null;
  }

  /// @Deprecated — use displayAmount + context.tr('common.currency') instead.
  @Deprecated('Use displayAmount and append context.tr("common.currency") in the UI layer')
  String? get displayPrice => displayAmount == null ? null : '$displayAmount DZD';

  @override
  List<Object?> get props => [
        id,
        userId,
        userName,
        userPhone,
        serviceType,
        title,
        description,
        scheduledDate,
        scheduledTime,
        priority,
        status,
        userLatitude,
        userLongitude,
        userAddress,
        mediaUrls,
        bidCount,
        biddingDeadlineAt,
        selectedBidId,
        budgetMin,
        budgetMax,
        workerId,
        workerName,
        agreedPrice,
        createdAt,
        bidSelectedAt,
        acceptedAt,
        completedAt,
        workerNotes,
        finalPrice,
        estimatedPrice,
        estimatedDuration,
        clientRating,
        reviewComment,
        cellId,
        wilayaCode,
        geoHash,
        lastCellUpdate,
      ];
}
