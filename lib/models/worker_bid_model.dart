// lib/models/worker_bid_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

import 'message_enums.dart';

// Sentinel used by copyWith to distinguish "caller explicitly passed null"
// from "caller did not pass this argument".
const _kUndefined = Object();

class WorkerBidModel extends Equatable {
  final String id;
  final String serviceRequestId;
  final String workerId;
  final String workerName;
  final double workerAverageRating;
  final int workerJobsCompleted;
  final String? workerProfileImageUrl;
  final double proposedPrice;
  final int estimatedMinutes;
  final DateTime availableFrom;
  final String? message;
  final BidStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? acceptedAt;

  const WorkerBidModel({
    required this.id,
    required this.serviceRequestId,
    required this.workerId,
    required this.workerName,
    required this.workerAverageRating,
    required this.workerJobsCompleted,
    this.workerProfileImageUrl,
    required this.proposedPrice,
    required this.estimatedMinutes,
    required this.availableFrom,
    this.message,
    required this.status,
    required this.createdAt,
    this.expiresAt,
    this.acceptedAt,
  });

  factory WorkerBidModel.fromMap(Map<String, dynamic> map, String id) {
    return WorkerBidModel(
      id: id,
      serviceRequestId: map['serviceRequestId'] as String? ?? '',
      workerId: map['workerId'] as String? ?? '',
      workerName: map['workerName'] as String? ?? '',
      workerAverageRating:
          (map['workerAverageRating'] as num?)?.toDouble() ?? 0.0,
      workerJobsCompleted: map['workerJobsCompleted'] as int? ?? 0,
      workerProfileImageUrl: map['workerProfileImageUrl'] as String?,
      proposedPrice: (map['proposedPrice'] as num?)?.toDouble() ?? 0.0,
      estimatedMinutes: map['estimatedMinutes'] as int? ?? 60,
      availableFrom:
          (map['availableFrom'] as Timestamp?)?.toDate() ?? DateTime.now(),
      message: map['message'] as String?,
      // FIX (QA P1): supports both legacy format ('BidStatus.pending' from
      // toString()) and new short format ('pending' from .name). The short
      // format is written by toMap() going forward.
      status: BidStatus.values.firstWhere(
        (e) => e.name == map['status'] || e.toString() == map['status'],
        orElse: () => BidStatus.pending,
      ),
      createdAt:
          (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt: (map['expiresAt'] as Timestamp?)?.toDate(),
      acceptedAt: (map['acceptedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'serviceRequestId': serviceRequestId,
      'workerId': workerId,
      'workerName': workerName,
      'workerAverageRating': workerAverageRating,
      'workerJobsCompleted': workerJobsCompleted,
      'workerProfileImageUrl': workerProfileImageUrl,
      'proposedPrice': proposedPrice,
      'estimatedMinutes': estimatedMinutes,
      'availableFrom': Timestamp.fromDate(availableFrom),
      'message': message,
      // FIX (QA P1): use .name instead of .toString() — stores 'pending'
      // rather than 'BidStatus.pending'. Robust to class renames and refactors.
      'status': status.name,
      'createdAt': Timestamp.fromDate(createdAt),
      'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt!) : null,
      'acceptedAt':
          acceptedAt != null ? Timestamp.fromDate(acceptedAt!) : null,
    };
  }

  // FIX (Engineer): nullable fields used `??` which made it impossible to
  // explicitly clear them via copyWith. Sentinel pattern applied.
  WorkerBidModel copyWith({
    String? id,
    String? serviceRequestId,
    String? workerId,
    String? workerName,
    double? workerAverageRating,
    int? workerJobsCompleted,
    Object? workerProfileImageUrl = _kUndefined,
    double? proposedPrice,
    int? estimatedMinutes,
    DateTime? availableFrom,
    Object? message = _kUndefined,
    BidStatus? status,
    DateTime? createdAt,
    Object? expiresAt = _kUndefined,
    Object? acceptedAt = _kUndefined,
  }) {
    return WorkerBidModel(
      id: id ?? this.id,
      serviceRequestId: serviceRequestId ?? this.serviceRequestId,
      workerId: workerId ?? this.workerId,
      workerName: workerName ?? this.workerName,
      workerAverageRating: workerAverageRating ?? this.workerAverageRating,
      workerJobsCompleted: workerJobsCompleted ?? this.workerJobsCompleted,
      workerProfileImageUrl: identical(workerProfileImageUrl, _kUndefined)
          ? this.workerProfileImageUrl
          : workerProfileImageUrl as String?,
      proposedPrice: proposedPrice ?? this.proposedPrice,
      estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
      availableFrom: availableFrom ?? this.availableFrom,
      message: identical(message, _kUndefined)
          ? this.message
          : message as String?,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: identical(expiresAt, _kUndefined)
          ? this.expiresAt
          : expiresAt as DateTime?,
      acceptedAt: identical(acceptedAt, _kUndefined)
          ? this.acceptedAt
          : acceptedAt as DateTime?,
    );
  }

  // Human-readable duration label
  String get estimatedDurationLabel {
    if (estimatedMinutes < 60) return '${estimatedMinutes}min';
    final hours = estimatedMinutes ~/ 60;
    final mins  = estimatedMinutes % 60;
    if (mins == 0) return '${hours}h';
    return '${hours}h${mins}min';
  }

  // Worker initials for avatar fallback
  String get workerInitials {
    final parts = workerName.trim().split(' ').where((w) => w.isNotEmpty).toList();
    // FIX (QA P1): previous impl used parts[0][0] without guarding against
    // an empty string segment — RangeError on edge-case names like '  '.
    if (parts.isEmpty) return '?';
    final first = parts[0];
    if (first.isEmpty) return '?';
    if (parts.length == 1) return first[0].toUpperCase();
    final second = parts[1];
    if (second.isEmpty) return first[0].toUpperCase();
    return '${first[0]}${second[0]}'.toUpperCase();
  }

  @override
  List<Object?> get props => [
        id,
        serviceRequestId,
        workerId,
        workerName,
        workerAverageRating,
        workerJobsCompleted,
        workerProfileImageUrl,
        proposedPrice,
        estimatedMinutes,
        availableFrom,
        message,
        status,
        createdAt,
        expiresAt,
        acceptedAt,
      ];
}
