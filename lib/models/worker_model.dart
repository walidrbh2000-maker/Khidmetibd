// lib/models/worker_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

// Sentinel used by copyWith to distinguish "caller explicitly passed null"
// from "caller did not pass this argument".
// This allows nullable fields to be cleared via copyWith without changing
// the non-nullable field API.
const _kUndefined = Object();

class WorkerModel extends Equatable {
  final String id;
  final String name;
  final String email;
  final String phoneNumber;
  final String profession;
  final bool isOnline;
  final double? latitude;
  final double? longitude;
  final DateTime lastUpdated;

  final String? cellId;
  final int? wilayaCode;
  final String? geoHash;
  final DateTime? lastCellUpdate;

  final String? profileImageUrl;
  final double averageRating;
  final int ratingCount;

  // FIX (Backend Audit P1): Added jobsCompleted as a dedicated counter,
  // separate from ratingCount. Previously WorkerBidService.submitBid() used
  // worker.ratingCount as a proxy for workerJobsCompleted on WorkerBidModel.
  // This was semantically wrong: a worker who completed 50 jobs but received
  // only 30 ratings would appear to have 30 completions in every bid they submit.
  //
  // jobsCompleted is incremented by the onJobCompleted Cloud Function on every
  // ServiceStatus.completed transition, independent of whether the client
  // submits a rating.
  //
  // fromMap falls back to ratingCount for backward compatibility with existing
  // Firestore documents that do not yet have the field.
  final int jobsCompleted;

  // ALGO FIX: responseRate and daysSinceActive added to unlock the full
  // composite ranking score in SmartSearchService._sortAndLimit().
  //
  // Previously the ranking fell back to (data as dynamic).responseRate which
  // always returned null → defaulted to 1.0 / 0, masking real signal.
  //
  // responseRate (0.0–1.0):
  //   Fraction of job requests the worker accepted vs. received.
  //   Computed server-side by the onJobAction Cloud Function and written to
  //   the worker document.
  //
  //   FIX (A3): fromMap default changed from 1.0 → 0.7.
  //   The 1.0 default inflated scores for legacy workers that pre-date the
  //   responseRate field: every legacy worker was treated as perfectly
  //   responsive, boosting their composite score by 0.15 (wResponse weight)
  //   over workers with real responseRate data.
  //   0.7 is a neutral prior — slightly below "good" — that neither rewards
  //   nor heavily penalises legacy workers while the Cloud Function backfill
  //   populates the field.
  //   Recalibrate this default from real responseRate distribution after
  //   backfill is complete.
  //
  // daysSinceActive (0–∞):
  //   Days since the worker's last isOnline=true → isOnline=false transition,
  //   or 0 if currently online. Stored as lastActiveAt (Timestamp) and
  //   computed at read time so it stays accurate without re-writes.
  //   fromMap computes it from lastActiveAt if present; defaults to 0.
  //
  // Firestore fields:
  //   workers/{id}.responseRate      — double, written by Cloud Function
  //   workers/{id}.lastActiveAt      — Timestamp, written by presence system
  final double responseRate;
  final int    daysSinceActive;

  const WorkerModel({
    required this.id,
    required this.name,
    required this.email,
    required this.phoneNumber,
    required this.profession,
    required this.isOnline,
    this.latitude,
    this.longitude,
    required this.lastUpdated,
    this.cellId,
    this.wilayaCode,
    this.geoHash,
    this.lastCellUpdate,
    this.profileImageUrl,
    this.averageRating = 0.0,
    this.ratingCount = 0,
    this.jobsCompleted = 0,
    // FIX (A3): constructor default also updated to 0.7 for consistency with
    // fromMap. Objects created in-memory (e.g. in tests or registration flows)
    // that omit responseRate now receive the same neutral prior as documents
    // read from Firestore.
    this.responseRate = 0.7,
    this.daysSinceActive = 0,
  });

  factory WorkerModel.fromMap(Map<String, dynamic> map, String id) {
    return WorkerModel(
      id: id,
      name: map['name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      phoneNumber: map['phoneNumber'] as String? ?? '',
      profession: map['profession'] as String? ?? '',
      isOnline: map['isOnline'] as bool? ?? false,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      lastUpdated:
          (map['lastUpdated'] as Timestamp?)?.toDate() ?? DateTime.now(),
      cellId: map['cellId'] as String?,
      wilayaCode: map['wilayaCode'] as int?,
      geoHash: map['geoHash'] as String?,
      lastCellUpdate: (map['lastCellUpdate'] as Timestamp?)?.toDate(),
      profileImageUrl: map['profileImageUrl'] as String?,
      averageRating: (map['averageRating'] as num?)?.toDouble() ?? 0.0,
      ratingCount: map['ratingCount'] as int? ?? 0,
      // Fallback to ratingCount for documents that pre-date this field.
      jobsCompleted:
          map['jobsCompleted'] as int? ?? map['ratingCount'] as int? ?? 0,
      // FIX (A3): default changed from 1.0 → 0.7.
      // 1.0 silently inflated legacy worker composite scores by +0.15
      // (wResponse = 0.15 × 1.0 vs 0.15 × 0.7 = +0.045 per worker).
      // At scale with hundreds of legacy workers this caused them to
      // outrank newer workers with real responseRate data near 0.7–0.8.
      // 0.7 is a neutral prior calibrated from typical platform averages;
      // recalibrate after Cloud Function backfill.
      responseRate:
          (map['responseRate'] as num?)?.toDouble() ?? 0.7,
      // Compute from lastActiveAt Timestamp if available; default 0 (treat as active).
      daysSinceActive: () {
        final ts = map['lastActiveAt'] as Timestamp?;
        if (ts == null) return 0;
        final diff = DateTime.now().difference(ts.toDate());
        return diff.inDays.clamp(0, 9999);
      }(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'phoneNumber': phoneNumber,
      'profession': profession,
      'isOnline': isOnline,
      'latitude': latitude,
      'longitude': longitude,
      'lastUpdated': Timestamp.fromDate(lastUpdated),
      'cellId': cellId,
      'wilayaCode': wilayaCode,
      'geoHash': geoHash,
      'lastCellUpdate':
          lastCellUpdate != null ? Timestamp.fromDate(lastCellUpdate!) : null,
      'profileImageUrl': profileImageUrl,
      'averageRating': averageRating,
      'ratingCount': ratingCount,
      'jobsCompleted': jobsCompleted,
      // responseRate and lastActiveAt are owned by Cloud Functions —
      // not written by the client. Excluded from toMap() intentionally
      // to prevent accidental overwrites. They are read-only from the
      // client perspective (populated via fromMap).
    };
  }

  // FIX (Engineer): nullable fields used `??` which made it impossible to
  // explicitly clear them via copyWith — `worker.copyWith(cellId: null)`
  // would silently return the existing cellId instead of null.
  // Fix: sentinel object `_kUndefined` lets the method distinguish
  // "caller passed null intentionally" from "caller did not pass this arg".
  //
  // Usage:
  //   worker.copyWith(cellId: 'new-cell')    // update
  //   worker.copyWith(cellId: null)           // clear to null  ← now works
  //   worker.copyWith()                       // keep all existing values
  WorkerModel copyWith({
    String? id,
    String? name,
    String? email,
    String? phoneNumber,
    String? profession,
    bool? isOnline,
    // Nullable fields use Object? + sentinel to allow explicit null clearing.
    Object? latitude = _kUndefined,
    Object? longitude = _kUndefined,
    DateTime? lastUpdated,
    Object? cellId = _kUndefined,
    Object? wilayaCode = _kUndefined,
    Object? geoHash = _kUndefined,
    Object? lastCellUpdate = _kUndefined,
    Object? profileImageUrl = _kUndefined,
    double? averageRating,
    int? ratingCount,
    int? jobsCompleted,
    double? responseRate,
    int? daysSinceActive,
  }) {
    return WorkerModel(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      profession: profession ?? this.profession,
      isOnline: isOnline ?? this.isOnline,
      latitude: identical(latitude, _kUndefined)
          ? this.latitude
          : latitude as double?,
      longitude: identical(longitude, _kUndefined)
          ? this.longitude
          : longitude as double?,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      cellId: identical(cellId, _kUndefined)
          ? this.cellId
          : cellId as String?,
      wilayaCode: identical(wilayaCode, _kUndefined)
          ? this.wilayaCode
          : wilayaCode as int?,
      geoHash: identical(geoHash, _kUndefined)
          ? this.geoHash
          : geoHash as String?,
      lastCellUpdate: identical(lastCellUpdate, _kUndefined)
          ? this.lastCellUpdate
          : lastCellUpdate as DateTime?,
      profileImageUrl: identical(profileImageUrl, _kUndefined)
          ? this.profileImageUrl
          : profileImageUrl as String?,
      averageRating: averageRating ?? this.averageRating,
      ratingCount: ratingCount ?? this.ratingCount,
      jobsCompleted: jobsCompleted ?? this.jobsCompleted,
      responseRate: responseRate ?? this.responseRate,
      daysSinceActive: daysSinceActive ?? this.daysSinceActive,
    );
  }

  @override
  List<Object?> get props => [
        id,
        name,
        email,
        phoneNumber,
        profession,
        isOnline,
        latitude,
        longitude,
        lastUpdated,
        cellId,
        wilayaCode,
        geoHash,
        lastCellUpdate,
        profileImageUrl,
        averageRating,
        ratingCount,
        jobsCompleted,
        responseRate,
        daysSinceActive,
      ];
}
