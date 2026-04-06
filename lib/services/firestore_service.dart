// lib/services/firestore_service.dart
//
// TASK 2 FIX — Added facade methods for new stream queries.
//
// NEW FACADES:
//   • streamOnlineWorkersByWilayas(wilayaCodes): delegates to
//     WorkerFirestoreRepository.streamOnlineWorkersByWilayas(). Used by
//     HomeController for geo-scoped real-time worker discovery.
//   • streamOnlineWorkersUnscoped({limit}): delegates to
//     WorkerFirestoreRepository.streamOnlineWorkersUnscoped(). Used as
//     HomeController fallback when wilaya lookup fails.
//   • streamWorkerAssignedRequests(workerId, {limit}): delegates to
//     ServiceRequestFirestoreRepository.streamWorkerAssignedRequests(). Used
//     by WorkerHomeController dashboard.
//
// [B3/B7 FIX] streamWorkerServiceRequests facade: forwarded new optional
//   wilayaCode parameter to the repository so callers can scope the openSub
//   query to the worker's wilaya instead of scanning platform-wide.

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/geographic_cell.dart';
import '../models/notification_model.dart';
import '../models/service_request_enhanced_model.dart';
import '../models/user_model.dart';
import '../models/worker_bid_model.dart';
import '../models/worker_model.dart';

import 'repositories/firestore_repository_base.dart';
import 'repositories/geo_cell_firestore_repository.dart';
import 'repositories/service_request_firestore_repository.dart';
import 'repositories/user_firestore_repository.dart';
import 'repositories/worker_firestore_repository.dart';

export 'repositories/firestore_repository_base.dart'
    show FirestoreServiceException;

class FirestoreService {
  static const String usersCollection           = 'users';
  static const String workersCollection         = 'workers';
  static const String serviceRequestsCollection = 'service_requests';
  static const String workerBidsCollection      = 'worker_bids';
  static const String notificationsCollection   = 'notifications';
  static const String cellsCollection           = 'geographic_cells';

  static const Duration operationTimeout     = FirestoreRepositoryBase.operationTimeout;
  static const int      maxRetries           = FirestoreRepositoryBase.maxRetries;
  static const Duration baseRetryDelay       = FirestoreRepositoryBase.baseRetryDelay;
  static const Duration cacheCleanupInterval = Duration(minutes: 10);
  static const int      maxCacheSize         = 100;
  static const Duration cacheTTL             = Duration(minutes: 15);

  final UserFirestoreRepository           _users;
  final WorkerFirestoreRepository         _workers;
  final ServiceRequestFirestoreRepository _requests;
  final GeoCellFirestoreRepository        _cells;

  Timer? _cacheCleanupTimer;
  bool   _isDisposed = false;

  final FirebaseFirestore firestore;

  FirestoreService({FirebaseFirestore? firestoreInstance})
      : firestore = firestoreInstance ?? FirebaseFirestore.instance,
        _users    = UserFirestoreRepository(
            firestoreInstance ?? FirebaseFirestore.instance),
        _workers  = WorkerFirestoreRepository(
            firestoreInstance ?? FirebaseFirestore.instance),
        _requests = ServiceRequestFirestoreRepository(
            firestoreInstance ?? FirebaseFirestore.instance),
        _cells    = GeoCellFirestoreRepository(
            firestoreInstance ?? FirebaseFirestore.instance);

  // ============================================================================
  // USER METHODS
  // ============================================================================

  Future<UserModel?> getUser(String userId) => _users.getUser(userId);
  Future<void> setUser(UserModel user) => _users.setUser(user);
  Future<void> createOrUpdateUser(UserModel user) => _users.createOrUpdateUser(user);
  Future<void> updateUserLocation(String userId, double lat, double lng) =>
      _users.updateUserLocation(userId, lat, lng);
  Future<void> updateUserFcmToken(String userId, String token) =>
      _users.updateFcmToken(userId, token);
  Future<void> updateFcmToken(String userId, String token) =>
      _users.updateFcmToken(userId, token);

  // ============================================================================
  // WORKER METHODS
  // ============================================================================

  Future<WorkerModel?> getWorker(String workerId) => _workers.getWorker(workerId);
  Future<void> setWorker(WorkerModel worker) => _workers.setWorker(worker);
  Future<void> createOrUpdateWorker(WorkerModel worker) =>
      _workers.createOrUpdateWorker(worker);

  Future<void> updateWorkerLocation(
    String workerId, double latitude, double longitude, {
    String? cellId, int? wilayaCode, String? geoHash,
  }) => _workers.updateWorkerLocation(workerId, latitude, longitude,
      cellId: cellId, wilayaCode: wilayaCode, geoHash: geoHash);

  Future<void> updateWorkerStatus(String workerId, bool isOnline) =>
      _workers.updateWorkerStatus(workerId, isOnline);
  Future<void> updateWorkerOnlineStatus(String workerId, bool isOnline) =>
      _workers.updateWorkerOnlineStatus(workerId, isOnline);
  Future<void> updateWorkerFcmToken(String workerId, String token) =>
      _workers.updateFcmToken(workerId, token);

  Future<List<WorkerModel>> getWorkersInCell({
    required String cellId, String? serviceType, bool onlineOnly = false,
  }) => _workers.getWorkersInCell(cellId: cellId,
      serviceType: serviceType, onlineOnly: onlineOnly);

  Future<List<WorkerModel>> getWorkersInWilaya({
    required int wilayaCode, String? serviceType, bool onlineOnly = false,
  }) => _workers.getWorkersInWilaya(wilayaCode: wilayaCode,
      serviceType: serviceType, onlineOnly: onlineOnly);

  Stream<WorkerModel?> streamWorker(String workerId) =>
      _workers.streamWorker(workerId);

  // ── TASK 2 — new worker stream facades ───────────────────────────────────

  /// Streams online workers whose wilayaCode is in [wilayaCodes].
  Stream<List<WorkerModel>> streamOnlineWorkersByWilayas(List<int> wilayaCodes) =>
      _workers.streamOnlineWorkersByWilayas(wilayaCodes);

  /// Fallback: streams all online workers up to [limit] (no wilaya filter).
  Stream<List<WorkerModel>> streamOnlineWorkersUnscoped({int limit = 100}) =>
      _workers.streamOnlineWorkersUnscoped(limit: limit);

  // ============================================================================
  // SERVICE REQUEST METHODS
  // ============================================================================

  Future<void> createServiceRequest(ServiceRequestEnhancedModel request) =>
      _requests.createServiceRequest(request);
  Future<ServiceRequestEnhancedModel?> getServiceRequest(String requestId) =>
      _requests.getServiceRequest(requestId);
  Future<void> updateServiceRequest(ServiceRequestEnhancedModel request) =>
      _requests.updateServiceRequest(request);
  Stream<ServiceRequestEnhancedModel?> streamServiceRequest(String requestId) =>
      _requests.streamServiceRequest(requestId);
  Stream<List<ServiceRequestEnhancedModel>> streamUserServiceRequests(
          String userId) =>
      _requests.streamUserServiceRequests(userId);

  // [B3/B7 FIX] Forwarded optional wilayaCode to the repository so the
  // openSub query inside streamWorkerServiceRequests() is geo-scoped when
  // the caller knows the worker's wilaya. Callers that cannot yet provide
  // wilayaCode continue to work via the unscoped fallback (now bounded to 50).
  Stream<List<ServiceRequestEnhancedModel>> streamWorkerServiceRequests(
          String workerId, {int? wilayaCode}) =>
      _requests.streamWorkerServiceRequests(workerId, wilayaCode: wilayaCode);

  Stream<List<ServiceRequestEnhancedModel>> streamAvailableRequests({
    required int wilayaCode, required String serviceType,
  }) => _requests.streamAvailableRequests(
      wilayaCode: wilayaCode, serviceType: serviceType);
  Stream<List<ServiceRequestEnhancedModel>> streamWorkerActiveJobs(
          String workerId) =>
      _requests.streamWorkerActiveJobs(workerId);
  Stream<List<WorkerBidModel>> streamBidsForRequest(String requestId) =>
      _requests.streamBidsForRequest(requestId);
  Stream<List<WorkerBidModel>> streamWorkerBids(String workerId) =>
      _requests.streamWorkerBids(workerId);
  Future<WorkerBidModel> createBid(WorkerBidModel bid) =>
      _requests.createBid(bid);
  Future<void> acceptBidTransaction({
    required String requestId, required String bidId,
    required String workerId, required String workerName,
    required double agreedPrice,
  }) => _requests.acceptBidTransaction(requestId: requestId, bidId: bidId,
      workerId: workerId, workerName: workerName, agreedPrice: agreedPrice);
  Future<void> withdrawBid({required String bidId, required String requestId}) =>
      _requests.withdrawBid(bidId: bidId, requestId: requestId);
  Future<void> startJob(String requestId) => _requests.startJob(requestId);
  Future<void> completeJob({
    required String requestId, String? workerNotes, double? finalPrice,
  }) => _requests.completeJob(requestId: requestId,
      workerNotes: workerNotes, finalPrice: finalPrice);
  Future<void> cancelRequest(String requestId) =>
      _requests.cancelRequest(requestId);
  Future<void> submitClientRating({
    required String requestId, required int stars, String? comment,
  }) => _requests.submitClientRating(requestId: requestId,
      stars: stars, comment: comment);

  // ── TASK 2 — new request stream facade ───────────────────────────────────

  Stream<List<ServiceRequestEnhancedModel>> streamWorkerAssignedRequests(
      String workerId, {int limit = 30}) =>
      _requests.streamWorkerAssignedRequests(workerId, limit: limit);

  // ============================================================================
  // NOTIFICATION METHODS
  // ============================================================================

  Future<void> createNotification(NotificationModel notification) =>
      _requests.createNotification(notification);

  // ============================================================================
  // GEOGRAPHIC CELL METHODS
  // ============================================================================

  Future<void> saveCell(GeographicCell cell) => _cells.saveCell(cell);
  Future<GeographicCell?> getCell(String cellId) => _cells.getCell(cellId);
  Future<List<GeographicCell>> getCellsInWilaya(int wilayaCode) =>
      _cells.getCellsInWilaya(wilayaCode);

  // ============================================================================
  // ATOMIC PROFILE CREATION
  // ============================================================================

  Future<void> atomicCreateUserProfile({
    UserModel? user, WorkerModel? worker,
  }) async {
    if (_isDisposed) {
      throw FirestoreServiceException(
        'FirestoreService has been disposed', code: 'SERVICE_DISPOSED');
    }
    if (user == null && worker == null) {
      throw FirestoreServiceException(
        'atomicCreateUserProfile: at least one of user or worker must be provided',
        code: 'INVALID_ARGUMENTS');
    }
    final uid = user?.id ?? worker!.id;
    try {
      final batch   = firestore.batch();
      final userRef = firestore.collection(usersCollection).doc(uid);
      if (user != null) {
        batch.set(userRef, user.toMap(), SetOptions(merge: true));
      } else if (worker != null) {
        final minimalUser = UserModel(
          id: uid, name: worker.name, email: worker.email,
          phoneNumber: worker.phoneNumber, lastUpdated: DateTime.now(),
        );
        batch.set(userRef, minimalUser.toMap(), SetOptions(merge: true));
      }
      if (worker != null) {
        final workerRef = firestore.collection(workersCollection).doc(uid);
        batch.set(workerRef, worker.toMap(), SetOptions(merge: true));
      }
      await batch.commit().timeout(operationTimeout);
      if (user != null)   _users.cacheUser(uid, user);
      if (worker != null) _workers.cacheWorker(uid, worker);
      _logInfo('atomicCreateUserProfile: committed for $uid');
    } catch (e) {
      _logError('atomicCreateUserProfile', e);
      throw FirestoreServiceException(
        'Error creating user profile atomically',
        code: 'PROFILE_CREATE_FAILED', originalError: e);
    }
  }

  // ============================================================================
  // CACHE MANAGEMENT
  // ============================================================================

  void startCacheCleanup() {
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = Timer.periodic(cacheCleanupInterval, (_) {
      _users.cleanExpiredCache();
      _workers.cleanExpiredCache();
    });
    _logInfo('Cache cleanup started');
  }

  // ============================================================================
  // DISPOSE
  // ============================================================================

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = null;
    _users.dispose();
    _workers.dispose();
    _requests.dispose();
    _cells.dispose();
    _logInfo('FirestoreService disposed');
  }

  void _logInfo(String m) {
    if (kDebugMode) debugPrint('[FirestoreService] INFO: $m');
  }
  void _logError(String method, dynamic e) {
    if (kDebugMode) debugPrint('[FirestoreService] ERROR in $method: $e');
  }
}
