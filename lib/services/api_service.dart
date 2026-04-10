// lib/services/api_service.dart
//
// FIX (Registration P0): createOrUpdateUser / createOrUpdateWorker now build
// the HTTP payload field-by-field instead of spreading user.toMap().
//
// ROOT CAUSE: NestJS ValidationPipe is configured with
//   { whitelist: true, forbidNonWhitelisted: true }
// which means ANY field not declared in CreateUserDto / CreateWorkerDto
// (e.g. lastUpdated, cellId, wilayaCode, geoHash coming from toMap())
// causes a 400 Bad Request. This silently killed every new registration:
//   1. Firebase user created ✓
//   2. POST /users → 400 (extra fields) → ApiServiceException thrown
//   3. catch block in signUp() → _cleanupFailedSignUp() → Firebase user deleted
//   4. User sees "can't create account"
//
// FIX: explicit whitelisted payload — only fields present in CreateUserDto /
// CreateWorkerDto. No toMap() spreading anywhere in write paths.
//
// STEP 5 MIGRATION: Replaces FirestoreService + all Firestore repositories.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/geographic_cell.dart';
import '../models/notification_model.dart';
import '../models/service_request_enhanced_model.dart';
import '../models/user_model.dart';
import '../models/worker_bid_model.dart';
import '../models/worker_model.dart';
import 'api_cache.dart';
import 'realtime_service.dart';

export 'api_cache.dart' show ApiServiceException;

// ─────────────────────────────────────────────────────────────────────────────
// Exception
// ─────────────────────────────────────────────────────────────────────────────

class ApiServiceException implements Exception {
  final String  message;
  final String? code;
  final dynamic originalError;

  const ApiServiceException(this.message, {this.code, this.originalError});

  @override
  String toString() =>
      'ApiServiceException: $message${code != null ? ' ($code)' : ''}';
}

// ─────────────────────────────────────────────────────────────────────────────
// ApiService
// ─────────────────────────────────────────────────────────────────────────────

class ApiService {
  final String         _baseUrl;
  final RealtimeService _realtime;
  final http.Client    _http;

  final ApiCache<UserModel>                       _userCache;
  final ApiCache<WorkerModel>                     _workerCache;
  final ApiCache<ServiceRequestEnhancedModel>     _requestCache;

  static const Duration _operationTimeout = Duration(seconds: 10);
  static const Duration _cacheTTL         = Duration(minutes: 15);
  static const int      _cacheMaxSize     = 100;

  bool _isDisposed = false;
  Timer? _cacheCleanupTimer;

  static const String usersCollection           = 'users';
  static const String workersCollection         = 'workers';
  static const String serviceRequestsCollection = 'service_requests';
  static const String workerBidsCollection      = 'worker_bids';
  static const String notificationsCollection   = 'notifications';
  static const String cellsCollection           = 'geographic_cells';

  ApiService({
    required String        baseUrl,
    required RealtimeService realtime,
    http.Client?           httpClient,
  })  : _baseUrl  = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _realtime = realtime,
        _http     = httpClient ?? http.Client(),
        _userCache    = ApiCache(ttl: _cacheTTL, maxSize: _cacheMaxSize, tag: '[UserCache]'),
        _workerCache  = ApiCache(ttl: _cacheTTL, maxSize: _cacheMaxSize, tag: '[WorkerCache]'),
        _requestCache = ApiCache(ttl: _cacheTTL, maxSize: _cacheMaxSize, tag: '[RequestCache]') {
    startCacheCleanup();
  }

  // ── Auth token ─────────────────────────────────────────────────────────────

  Future<Map<String, String>> _authHeaders() async {
    final user  = FirebaseAuth.instance.currentUser;
    final token = await user?.getIdToken();
    return {
      'Content-Type':  'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, String>> _authHeadersNoContentType() async {
    final user  = FirebaseAuth.instance.currentUser;
    final token = await user?.getIdToken();
    return {
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // ── HTTP helpers ───────────────────────────────────────────────────────────

  Future<dynamic> _get(String path) async {
    _ensureNotDisposed();
    final headers  = await _authHeaders();
    final uri      = Uri.parse('$_baseUrl$path');
    try {
      final response = await _http.get(uri, headers: headers)
          .timeout(_operationTimeout);
      return _handleResponse(response);
    } on ApiServiceException {
      rethrow;
    } catch (e) {
      throw ApiServiceException('GET $path failed', code: 'NETWORK_ERROR', originalError: e);
    }
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    _ensureNotDisposed();
    final headers  = await _authHeaders();
    final uri      = Uri.parse('$_baseUrl$path');
    try {
      final response = await _http.post(uri, headers: headers, body: jsonEncode(body))
          .timeout(_operationTimeout);
      return _handleResponse(response);
    } on ApiServiceException {
      rethrow;
    } catch (e) {
      throw ApiServiceException('POST $path failed', code: 'NETWORK_ERROR', originalError: e);
    }
  }

  Future<dynamic> _patch(String path, Map<String, dynamic> body) async {
    _ensureNotDisposed();
    final headers  = await _authHeaders();
    final uri      = Uri.parse('$_baseUrl$path');
    try {
      final response = await _http.patch(uri, headers: headers, body: jsonEncode(body))
          .timeout(_operationTimeout);
      return _handleResponse(response);
    } on ApiServiceException {
      rethrow;
    } catch (e) {
      throw ApiServiceException('PATCH $path failed', code: 'NETWORK_ERROR', originalError: e);
    }
  }

  dynamic _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['success'] == true && decoded.containsKey('data')) {
        return decoded['data'];
      }
      return decoded;
    }
    String message = 'Request failed (${response.statusCode})';
    String? code;
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      message = body['message'] as String? ?? message;
      code    = response.statusCode.toString();
    } catch (_) {}
    if (response.statusCode == 401) throw ApiServiceException(message, code: 'UNAUTHENTICATED');
    if (response.statusCode == 403) throw ApiServiceException(message, code: 'PERMISSION_DENIED');
    if (response.statusCode == 404) throw ApiServiceException(message, code: 'NOT_FOUND');
    if (response.statusCode == 409) throw ApiServiceException(message, code: 'ALREADY_EXISTS');
    if (response.statusCode == 429) throw ApiServiceException(message, code: 'RESOURCE_EXHAUSTED');
    throw ApiServiceException(message, code: code ?? 'UNKNOWN');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // USER METHODS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<UserModel?> getUser(String userId) async {
    _ensureNotDisposed();
    if (userId.trim().isEmpty) return null;
    final cached = _userCache.get(userId);
    if (cached != null) return cached;
    try {
      final data = await _get('/users/$userId');
      if (data == null) return null;
      final user = UserModel.fromJson(data as Map<String, dynamic>);
      _userCache.set(userId, user);
      return user;
    } on ApiServiceException catch (e) {
      if (e.code == 'NOT_FOUND') return null;
      rethrow;
    }
  }

  Future<void> setUser(UserModel user) => createOrUpdateUser(user);

  /// FIX: explicit whitelisted payload matching CreateUserDto exactly.
  /// No toMap() spreading — avoids 400 from forbidNonWhitelisted.
  Future<void> createOrUpdateUser(UserModel user) async {
    _ensureNotDisposed();

    // Build payload with ONLY fields declared in NestJS CreateUserDto.
    // forbidNonWhitelisted=true will 400 any extra key (lastUpdated, cellId, etc.)
    final payload = <String, dynamic>{
      'id':    user.id,
      'name':  user.name,
      'email': user.email,
    };
    if (user.phoneNumber?.isNotEmpty == true) payload['phoneNumber']     = user.phoneNumber;
    if (user.latitude        != null)         payload['latitude']        = user.latitude;
    if (user.longitude       != null)         payload['longitude']       = user.longitude;
    if (user.profileImageUrl != null)         payload['profileImageUrl'] = user.profileImageUrl;
    if (user.fcmToken        != null)         payload['fcmToken']        = user.fcmToken;

    final data = await _post('/users', payload);
    if (data != null) {
      final updated = UserModel.fromJson(data as Map<String, dynamic>);
      _userCache.set(user.id, updated);
    }
  }

  Future<void> updateUserLocation(
    String userId, double lat, double lng, {
    String? cellId, int? wilayaCode, String? geoHash,
  }) async {
    _ensureNotDisposed();
    await _patch('/users/$userId/location', {
      'latitude': lat,
      'longitude': lng,
      if (cellId     != null) 'cellId':     cellId,
      if (wilayaCode != null) 'wilayaCode': wilayaCode,
      if (geoHash    != null) 'geoHash':    geoHash,
    });
  }

  Future<void> updateFcmToken(String userId, String token) async {
    _ensureNotDisposed();
    await _patch('/users/$userId/fcm-token', {'fcmToken': token});
  }

  Future<void> updateUserFcmToken(String userId, String token) =>
      updateFcmToken(userId, token);

  // ═══════════════════════════════════════════════════════════════════════════
  // WORKER METHODS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<WorkerModel?> getWorker(String workerId) async {
    _ensureNotDisposed();
    if (workerId.trim().isEmpty) return null;
    final cached = _workerCache.get(workerId);
    if (cached != null) return cached;
    try {
      final data = await _get('/workers/$workerId');
      if (data == null) return null;
      final worker = WorkerModel.fromJson(data as Map<String, dynamic>);
      _workerCache.set(workerId, worker);
      return worker;
    } on ApiServiceException catch (e) {
      if (e.code == 'NOT_FOUND') return null;
      rethrow;
    }
  }

  Future<void> setWorker(WorkerModel worker) => createOrUpdateWorker(worker);

  /// FIX: explicit whitelisted payload matching CreateWorkerDto exactly.
  /// No toMap() spreading — avoids 400 from forbidNonWhitelisted.
  Future<void> createOrUpdateWorker(WorkerModel worker) async {
    _ensureNotDisposed();

    // Build payload with ONLY fields declared in NestJS CreateWorkerDto.
    final payload = <String, dynamic>{
      'id':         worker.id,
      'name':       worker.name,
      'email':      worker.email,
      'profession': worker.profession,
      'isOnline':   worker.isOnline,
    };
    if (worker.phoneNumber?.isNotEmpty == true) payload['phoneNumber']     = worker.phoneNumber;
    if (worker.latitude        != null)         payload['latitude']        = worker.latitude;
    if (worker.longitude       != null)         payload['longitude']       = worker.longitude;
    if (worker.profileImageUrl != null)         payload['profileImageUrl'] = worker.profileImageUrl;
    if (worker.fcmToken        != null)         payload['fcmToken']        = worker.fcmToken;

    final data = await _post('/workers', payload);
    if (data != null) {
      final updated = WorkerModel.fromJson(data as Map<String, dynamic>);
      _workerCache.set(worker.id, updated);
    }
  }

  Future<void> updateWorkerLocation(
    String workerId, double latitude, double longitude, {
    String? cellId, int? wilayaCode, String? geoHash,
  }) async {
    _ensureNotDisposed();
    await _patch('/workers/$workerId/location', {
      'latitude':  latitude,
      'longitude': longitude,
      if (cellId     != null) 'cellId':     cellId,
      if (wilayaCode != null) 'wilayaCode': wilayaCode,
      if (geoHash    != null) 'geoHash':    geoHash,
    });
  }

  Future<void> updateWorkerStatus(String workerId, bool isOnline) async {
    _ensureNotDisposed();
    await _patch('/workers/$workerId/status', {'isOnline': isOnline});
    _workerCache.update(workerId, (w) => w.copyWith(isOnline: isOnline));
  }

  Future<void> updateWorkerOnlineStatus(String workerId, bool isOnline) =>
      updateWorkerStatus(workerId, isOnline);

  Future<void> updateWorkerFcmToken(String workerId, String token) async {
    _ensureNotDisposed();
    await _patch('/workers/$workerId/fcm-token', {'fcmToken': token});
  }

  Future<List<WorkerModel>> getWorkersInCell({
    required String cellId, String? serviceType, bool onlineOnly = false,
  }) async {
    _ensureNotDisposed();
    final q = StringBuffer('/location/cells/$cellId/workers?limit=50');
    if (serviceType != null) q.write('&serviceType=$serviceType');
    if (onlineOnly)           q.write('&onlineOnly=true');
    final data = await _get(q.toString());
    if (data == null) return [];
    return (data as List).map((e) => WorkerModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<WorkerModel>> getWorkersInWilaya({
    required int wilayaCode, String? serviceType, bool onlineOnly = false,
  }) async {
    _ensureNotDisposed();
    final q = StringBuffer('/workers?wilayaCode=$wilayaCode&limit=50');
    if (serviceType != null) q.write('&profession=$serviceType');
    if (onlineOnly)           q.write('&isOnline=true');
    final data = await _get(q.toString());
    if (data == null) return [];
    return (data as List).map((e) => WorkerModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Stream<WorkerModel?> streamWorker(String workerId) =>
      _realtime.streamWorker(workerId);

  Stream<List<WorkerModel>> streamOnlineWorkersByWilayas(List<int> wilayaCodes) =>
      _realtime.streamOnlineWorkersByWilayas(wilayaCodes);

  Stream<List<WorkerModel>> streamOnlineWorkersUnscoped({int limit = 100}) =>
      _realtime.streamOnlineWorkersUnscoped(limit: limit);

  // ═══════════════════════════════════════════════════════════════════════════
  // SERVICE REQUEST METHODS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> createServiceRequest(ServiceRequestEnhancedModel request) async {
    _ensureNotDisposed();
    final data = await _post('/service-requests', {
      'userId':          request.userId,
      'userName':        request.userName,
      'userPhone':       request.userPhone,
      'serviceType':     request.serviceType,
      'title':           request.title,
      'description':     request.description,
      'scheduledDate':   request.scheduledDate.toIso8601String(),
      'scheduledHour':   request.scheduledTime.hour,
      'scheduledMinute': request.scheduledTime.minute,
      'priority':        request.priority.name,
      'userLatitude':    request.userLatitude,
      'userLongitude':   request.userLongitude,
      'userAddress':     request.userAddress,
      'mediaUrls':       request.mediaUrls,
      if (request.budgetMin   != null) 'budgetMin':   request.budgetMin,
      if (request.budgetMax   != null) 'budgetMax':   request.budgetMax,
      if (request.cellId      != null) 'cellId':      request.cellId,
      if (request.wilayaCode  != null) 'wilayaCode':  request.wilayaCode,
      if (request.geoHash     != null) 'geoHash':     request.geoHash,
    });
    if (data != null) {
      final created = ServiceRequestEnhancedModel.fromJson(data as Map<String, dynamic>);
      _requestCache.set(created.id, created);
    }
  }

  Future<ServiceRequestEnhancedModel?> getServiceRequest(String requestId) async {
    _ensureNotDisposed();
    if (requestId.trim().isEmpty) return null;
    final cached = _requestCache.get(requestId);
    if (cached != null) return cached;
    try {
      final data = await _get('/service-requests/$requestId');
      if (data == null) return null;
      final req = ServiceRequestEnhancedModel.fromJson(data as Map<String, dynamic>);
      _requestCache.set(requestId, req);
      return req;
    } on ApiServiceException catch (e) {
      if (e.code == 'NOT_FOUND') return null;
      rethrow;
    }
  }

  Future<void> updateServiceRequest(ServiceRequestEnhancedModel request) async {
    _ensureNotDisposed();
    await _patch('/service-requests/${request.id}', request.toMap());
    _requestCache.set(request.id, request);
  }

  Future<void> startJob(String requestId) async {
    _ensureNotDisposed();
    await _post('/service-requests/$requestId/start', {});
  }

  Future<void> completeJob({
    required String requestId, String? workerNotes, double? finalPrice,
  }) async {
    _ensureNotDisposed();
    await _post('/service-requests/$requestId/complete', {
      if (workerNotes != null) 'workerNotes': workerNotes,
      if (finalPrice  != null) 'finalPrice':  finalPrice,
    });
  }

  Future<void> cancelRequest(String requestId) async {
    _ensureNotDisposed();
    await _post('/service-requests/$requestId/cancel', {});
    _requestCache.clear();
  }

  Future<void> submitClientRating({
    required String requestId, required int stars, String? comment,
  }) async {
    _ensureNotDisposed();
    await _post('/service-requests/$requestId/rate', {
      'stars': stars,
      if (comment != null) 'comment': comment,
    });
  }

  // ── Streams ────────────────────────────────────────────────────────────────

  Stream<ServiceRequestEnhancedModel?> streamServiceRequest(String requestId) =>
      _realtime.streamServiceRequest(requestId);

  Stream<List<ServiceRequestEnhancedModel>> streamUserServiceRequests(String userId) =>
      _realtime.streamUserServiceRequests(userId);

  Stream<List<ServiceRequestEnhancedModel>> streamWorkerServiceRequests(
          String workerId, {int? wilayaCode}) =>
      _realtime.streamWorkerServiceRequests(workerId, wilayaCode: wilayaCode);

  Stream<List<ServiceRequestEnhancedModel>> streamAvailableRequests({
    required int wilayaCode, required String serviceType,
  }) => _realtime.streamAvailableRequests(wilayaCode: wilayaCode, serviceType: serviceType);

  Stream<List<ServiceRequestEnhancedModel>> streamWorkerActiveJobs(String workerId) =>
      _realtime.streamWorkerActiveJobs(workerId);

  Stream<List<ServiceRequestEnhancedModel>> streamWorkerAssignedRequests(
          String workerId, {int limit = 30}) =>
      _realtime.streamWorkerAssignedRequests(workerId, limit: limit);

  // ── Bids ───────────────────────────────────────────────────────────────────

  Stream<List<WorkerBidModel>> streamBidsForRequest(String requestId) =>
      _realtime.streamBidsForRequest(requestId);

  Stream<List<WorkerBidModel>> streamWorkerBids(String workerId) =>
      _realtime.streamWorkerBids(workerId);

  Future<WorkerBidModel> createBid(WorkerBidModel bid) async {
    _ensureNotDisposed();
    final data = await _post('/bids', bid.toMap());
    return WorkerBidModel.fromJson(data as Map<String, dynamic>);
  }

  Future<void> acceptBidTransaction({
    required String requestId, required String bidId,
    required String workerId, required String workerName, required double agreedPrice,
  }) async {
    _ensureNotDisposed();
    await _post('/bids/$bidId/accept', {'requestId': requestId});
  }

  Future<void> withdrawBid({required String bidId, required String requestId}) async {
    _ensureNotDisposed();
    await _post('/bids/$bidId/withdraw', {});
  }

  // ── Notifications ──────────────────────────────────────────────────────────

  Future<void> createNotification(NotificationModel notification) async {
    _ensureNotDisposed();
    _logInfo('createNotification: no-op (server-push only in new stack)');
  }

  // ── Geographic cells ───────────────────────────────────────────────────────

  Future<void> saveCell(GeographicCell cell) async {
    _ensureNotDisposed();
    _logInfo('saveCell: no-op (server-side only in new stack)');
  }

  Future<GeographicCell?> getCell(String cellId) async {
    _ensureNotDisposed();
    try {
      final data = await _get('/location/cells/$cellId/adjacent');
      if (data == null) return null;
      final adjacentIds = (data['adjacentCellIds'] as List?)
          ?.map((e) => e.toString())
          .toList() ?? [];
      final parts = cellId.split('_');
      if (parts.length != 3) return null;
      return GeographicCell(
        id:               cellId,
        wilayaCode:       int.tryParse(parts[0]) ?? 0,
        centerLat:        double.tryParse(parts[1]) ?? 0,
        centerLng:        double.tryParse(parts[2]) ?? 0,
        radius:           5.0,
        adjacentCellIds:  adjacentIds,
      );
    } on ApiServiceException catch (e) {
      if (e.code == 'NOT_FOUND') return null;
      rethrow;
    }
  }

  Future<List<GeographicCell>> getCellsInWilaya(int wilayaCode) async => [];

  // ── Atomic profile creation ────────────────────────────────────────────────

  Future<void> atomicCreateUserProfile({UserModel? user, WorkerModel? worker}) async {
    _ensureNotDisposed();
    if (worker != null) {
      await createOrUpdateWorker(worker);
    }
    if (user != null) {
      await createOrUpdateUser(user);
    }
  }

  // ── Cache management ───────────────────────────────────────────────────────

  void startCacheCleanup() {
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      _userCache.cleanExpired();
      _workerCache.cleanExpired();
      _requestCache.cleanExpired();
    });
  }

  void cacheUser(String userId, UserModel user)    => _userCache.set(userId, user);
  void cacheWorker(String workerId, WorkerModel w) => _workerCache.set(workerId, w);
  void cleanExpiredCache() {
    _userCache.cleanExpired();
    _workerCache.cleanExpired();
    _requestCache.cleanExpired();
  }

  _ApiDirectClient get firestore => _ApiDirectClient(this);

  // ── Dispose ────────────────────────────────────────────────────────────────

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _cacheCleanupTimer?.cancel();
    _userCache.clear();
    _workerCache.clear();
    _requestCache.clear();
    _http.close();
    _logInfo('ApiService disposed');
  }

  void _ensureNotDisposed() {
    if (_isDisposed) throw const ApiServiceException('ApiService has been disposed', code: 'SERVICE_DISPOSED');
  }

  void _logInfo(String m) {
    if (kDebugMode) debugPrint('[ApiService] $m');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ApiDirectClient shim (unchanged)
// ─────────────────────────────────────────────────────────────────────────────

class _ApiDirectClient {
  final ApiService _api;
  const _ApiDirectClient(this._api);

  _CollectionRef collection(String name) => _CollectionRef(_api, name);
}

class _CollectionRef {
  final ApiService _api;
  final String     _collection;
  const _CollectionRef(this._api, this._collection);

  _DocRef doc(String id) => _DocRef(_api, _collection, id);

  _QueryRef where(String field, {dynamic isEqualTo, bool? isNull}) =>
      _QueryRef(_api, _collection, field, isEqualTo: isEqualTo, isNull: isNull);
}

class _DocRef {
  final ApiService _api;
  final String     _collection;
  final String     _id;
  const _DocRef(this._api, this._collection, this._id);

  Future<_DocSnapshot> get() async {
    try {
      final data = await _api._get('/$_collection/$_id');
      return _DocSnapshot(id: _id, data: data as Map<String, dynamic>?, exists: data != null);
    } on ApiServiceException catch (e) {
      if (e.code == 'NOT_FOUND') return _DocSnapshot(id: _id, data: null, exists: false);
      rethrow;
    }
  }

  Future<void> set(Map<String, dynamic> data, [dynamic options]) async {
    await _api._post('/$_collection', {'id': _id, ...data});
  }

  Future<void> update(Map<String, dynamic> data) async {
    await _api._patch('/$_collection/$_id', data);
  }

  Future<void> delete() async {
    if (kDebugMode) debugPrint('[ApiDirectClient] delete not fully implemented for $_collection/$_id');
  }
}

class _DocSnapshot {
  final String               id;
  final Map<String, dynamic>? _data;
  final bool                 exists;

  const _DocSnapshot({required this.id, required Map<String, dynamic>? data, required this.exists})
      : _data = data;

  Map<String, dynamic>? data() => _data;
}

class _QueryRef {
  final ApiService _api;
  final String     _collection;
  final String     _field;
  final dynamic    _isEqualTo;
  final bool?      _isNull;

  const _QueryRef(this._api, this._collection, this._field,
      {dynamic isEqualTo, bool? isNull})
      : _isEqualTo = isEqualTo,
        _isNull    = isNull;

  _QueryRef where(String field, {dynamic isEqualTo, bool? isNull}) =>
      _QueryRef(_api, _collection, field, isEqualTo: isEqualTo, isNull: isNull);

  _QueryRef limit(int n) => this;

  Future<_QuerySnapshot> get() async {
    final q = StringBuffer('/$_collection?');
    if (_isEqualTo != null) q.write('$_field=${Uri.encodeComponent(_isEqualTo.toString())}&');
    q.write('limit=50');
    final data = await _api._get(q.toString());
    if (data == null) return _QuerySnapshot([]);
    final docs = (data as List)
        .map((e) {
          final m = e as Map<String, dynamic>;
          final id = (m['_id'] ?? m['id'] ?? '') as String;
          return _DocSnapshot(id: id, data: m, exists: true);
        })
        .toList();
    return _QuerySnapshot(docs);
  }
}

class _QuerySnapshot {
  final List<_DocSnapshot> docs;
  const _QuerySnapshot(this.docs);
}
