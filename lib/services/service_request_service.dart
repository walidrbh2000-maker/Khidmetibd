// lib/services/service_request_service.dart
//
// [AUTO FIX] completeServiceRequest: status guard updated from
//   ServiceStatus.accepted → ServiceStatus.bidSelected to match the hybrid bid
//   model. The `accepted` status is never set in the current flow, so the old
//   guard made it impossible to complete any job.
//
// [AUTO FIX] _validateCoordinates: added (0.0, 0.0) zero-coordinate guard.
//   lat=0.0/lng=0.0 is the default value emitted before the device GPS lock
//   is acquired (Null Island, Gulf of Guinea). Submitting a request with these
//   coordinates places it in the wrong wilaya and makes it invisible to workers
//   in the client's actual location.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/service_request_enhanced_model.dart';
import '../models/message_enums.dart';
import 'firestore_service.dart';
import 'media_service.dart';
import 'geographic_grid_service.dart';

class ServiceRequestServiceException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  ServiceRequestServiceException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() =>
      'ServiceRequestServiceException: $message${code != null ? ' (Code: $code)' : ''}';
}

class ServiceRequestService {
  static const int defaultWilayaCode = 16;
  static const int minTitleLength = 3;
  static const int maxTitleLength = 100;
  static const int minDescriptionLength = 10;
  static const int maxDescriptionLength = 1000;
  static const int maxMediaUrls = 5;
  static const Duration operationTimeout = Duration(seconds: 30);
  static const double minPrice = 0.0;
  static const double maxPrice = 1000000.0;

  final FirestoreService firestoreService;
  final MediaService mediaService;
  final GeographicGridService geographicGridService;

  bool _isDisposed = false;

  ServiceRequestService(
    this.firestoreService,
    this.mediaService,
    this.geographicGridService,
  );

  bool get isDisposed => _isDisposed;

  Future<ServiceRequestEnhancedModel> createServiceRequest({
    required String userId,
    required String userName,
    required String userPhone,
    required String serviceType,
    required String title,
    required String description,
    required DateTime scheduledDate,
    required TimeOfDay scheduledTime,
    required ServicePriority priority,
    required double userLatitude,
    required double userLongitude,
    required String userAddress,
    List<String> mediaUrls = const [],
  }) async {
    _ensureNotDisposed();

    _validateCreateRequestInput(
      userId: userId,
      userName: userName,
      userPhone: userPhone,
      serviceType: serviceType,
      title: title,
      description: description,
      scheduledDate: scheduledDate,
      userLatitude: userLatitude,
      userLongitude: userLongitude,
      userAddress: userAddress,
      mediaUrls: mediaUrls,
    );

    try {
      _logInfo('Creating service request: $title');

      final wilayaCode = geographicGridService.getWilayaCodeFromCoordinates(
        userLatitude,
        userLongitude,
      );

      if (wilayaCode == null) {
        _logWarning(
            'Could not determine wilaya code, using default: $defaultWilayaCode');
      }

      final effectiveWilayaCode = wilayaCode ?? defaultWilayaCode;

      final cell = await geographicGridService
          .getCellForLocation(
            userLatitude,
            userLongitude,
            effectiveWilayaCode,
          )
          .timeout(
            operationTimeout,
            onTimeout: () {
              _logWarning('Cell location lookup timed out');
              return null;
            },
          );

      final requestId = _generateRequestId();

      final request = ServiceRequestEnhancedModel(
        id: requestId,
        userId: userId.trim(),
        userName: userName.trim(),
        userPhone: userPhone.trim(),
        serviceType: serviceType.trim(),
        title: title.trim(),
        description: description.trim(),
        scheduledDate: scheduledDate,
        scheduledTime: scheduledTime,
        priority: priority,
        status: ServiceStatus.open,
        userLatitude: userLatitude,
        userLongitude: userLongitude,
        userAddress: userAddress.trim(),
        mediaUrls: mediaUrls,
        createdAt: DateTime.now(),
        cellId: cell?.id,
        wilayaCode: effectiveWilayaCode,
      );

      await firestoreService
          .createServiceRequest(request)
          .timeout(operationTimeout);

      _logInfo('Service request created successfully: ${request.id}');
      return request;
    } on TimeoutException {
      throw ServiceRequestServiceException(
        'Request creation timed out',
        code: 'CREATE_TIMEOUT',
      );
    } catch (e) {
      _logError('createServiceRequest', e);
      if (e is ServiceRequestServiceException) rethrow;
      throw ServiceRequestServiceException(
        'Failed to create service request',
        code: 'CREATE_REQUEST_ERROR',
        originalError: e,
      );
    }
  }

  Future<void> updateServiceRequest(
    ServiceRequestEnhancedModel request,
  ) async {
    _ensureNotDisposed();
    _validateServiceRequest(request);

    try {
      _logInfo('Updating service request: ${request.id}');

      await firestoreService
          .updateServiceRequest(request)
          .timeout(operationTimeout);

      _logInfo('Service request updated successfully: ${request.id}');
    } on TimeoutException {
      throw ServiceRequestServiceException(
        'Request update timed out',
        code: 'UPDATE_TIMEOUT',
      );
    } catch (e) {
      _logError('updateServiceRequest', e);
      if (e is ServiceRequestServiceException) rethrow;
      throw ServiceRequestServiceException(
        'Failed to update service request',
        code: 'UPDATE_REQUEST_ERROR',
        originalError: e,
      );
    }
  }

  // DEPRECATED (Architect P0): This method belongs to the pre-hybrid model.
  @Deprecated(
    'Use WorkerBidService.acceptBid() instead. '
    'This method operates on the legacy ServiceStatus.pending / accepted model '
    'which is no longer used in the hybrid bid flow and will corrupt state '
    'if called on a live request.',
  )
  Future<void> acceptServiceRequest({
    required String requestId,
    required String workerId,
  }) async {
    throw ServiceRequestServiceException(
      'acceptServiceRequest is no longer supported in the hybrid bid model. '
      'Use WorkerBidService.acceptBid() to perform the correct '
      'acceptBidTransaction (open → bidSelected).',
      code: 'METHOD_REMOVED',
    );
  }

  /// [AUTO FIX] Status guard updated: ServiceStatus.accepted → bidSelected.
  ///
  /// In the hybrid bid model the request transitions:
  ///   open → awaitingSelection → bidSelected → inProgress → completed
  ///
  /// `accepted` is a legacy status that is never written in the current flow.
  /// The old guard (`accepted || inProgress`) made completeServiceRequest
  /// unreachable via the normal worker-completes-job path because the request
  /// would always be in `bidSelected` or `inProgress` — never `accepted`.
  Future<void> completeServiceRequest({
    required String requestId,
    String? workerNotes,
    double? finalPrice,
  }) async {
    _ensureNotDisposed();
    _validateRequestId(requestId);

    if (workerNotes != null && workerNotes.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'Worker notes cannot be empty if provided',
        code: 'INVALID_NOTES',
      );
    }

    if (finalPrice != null) {
      _validatePrice(finalPrice);
    }

    try {
      _logInfo('Completing service request: $requestId');

      final request = await firestoreService
          .getServiceRequest(requestId)
          .timeout(operationTimeout);

      if (request == null) {
        throw ServiceRequestServiceException(
          'Service request not found: $requestId',
          code: 'REQUEST_NOT_FOUND',
        );
      }

      // [AUTO FIX] Accept bidSelected (hybrid model) OR inProgress.
      // Legacy `accepted` status is never set in the hybrid bid flow.
      if (request.status != ServiceStatus.bidSelected &&
          request.status != ServiceStatus.inProgress) {
        throw ServiceRequestServiceException(
          'Service request cannot be completed. Current status: ${request.status.name}. '
          'Expected bidSelected or inProgress.',
          code: 'INVALID_STATUS',
        );
      }

      final updatedRequest = request.copyWith(
        status: ServiceStatus.completed,
        completedAt: DateTime.now(),
        workerNotes: workerNotes,
        finalPrice: finalPrice,
      );

      await firestoreService
          .updateServiceRequest(updatedRequest)
          .timeout(operationTimeout);

      _logInfo('Service request completed successfully: $requestId');
    } on TimeoutException {
      throw ServiceRequestServiceException(
        'Request completion timed out',
        code: 'COMPLETE_TIMEOUT',
      );
    } catch (e) {
      _logError('completeServiceRequest', e);
      if (e is ServiceRequestServiceException) rethrow;
      throw ServiceRequestServiceException(
        'Failed to complete service request',
        code: 'COMPLETE_REQUEST_ERROR',
        originalError: e,
      );
    }
  }

  Future<void> cancelServiceRequest({
    required String requestId,
  }) async {
    _ensureNotDisposed();
    _validateRequestId(requestId);

    try {
      _logInfo('Cancelling service request: $requestId');

      final request = await firestoreService
          .getServiceRequest(requestId)
          .timeout(operationTimeout);

      if (request == null) {
        throw ServiceRequestServiceException(
          'Service request not found: $requestId',
          code: 'REQUEST_NOT_FOUND',
        );
      }

      if (request.status == ServiceStatus.completed ||
          request.status == ServiceStatus.cancelled) {
        throw ServiceRequestServiceException(
          'Service request cannot be cancelled. Current status: ${request.status}',
          code: 'INVALID_STATUS',
        );
      }

      final updatedRequest = request.copyWith(
        status: ServiceStatus.cancelled,
      );

      await firestoreService
          .updateServiceRequest(updatedRequest)
          .timeout(operationTimeout);

      _logInfo('Service request cancelled successfully: $requestId');
    } on TimeoutException {
      throw ServiceRequestServiceException(
        'Request cancellation timed out',
        code: 'CANCEL_TIMEOUT',
      );
    } catch (e) {
      _logError('cancelServiceRequest', e);
      if (e is ServiceRequestServiceException) rethrow;
      throw ServiceRequestServiceException(
        'Failed to cancel service request',
        code: 'CANCEL_REQUEST_ERROR',
        originalError: e,
      );
    }
  }

  Future<ServiceRequestEnhancedModel?> getServiceRequest(
    String requestId,
  ) async {
    _ensureNotDisposed();
    _validateRequestId(requestId);

    try {
      return await firestoreService
          .getServiceRequest(requestId)
          .timeout(operationTimeout);
    } on TimeoutException {
      throw ServiceRequestServiceException(
        'Get request timed out',
        code: 'GET_TIMEOUT',
      );
    } catch (e) {
      _logError('getServiceRequest', e);
      if (e is ServiceRequestServiceException) rethrow;
      throw ServiceRequestServiceException(
        'Failed to get service request',
        code: 'GET_REQUEST_ERROR',
        originalError: e,
      );
    }
  }

  Stream<List<ServiceRequestEnhancedModel>> streamUserServiceRequests(
    String userId,
  ) {
    _ensureNotDisposed();
    _validateUserId(userId);

    try {
      return firestoreService.streamUserServiceRequests(userId);
    } catch (e) {
      _logError('streamUserServiceRequests', e);
      return Stream.error(
        ServiceRequestServiceException(
          'Failed to stream user service requests',
          code: 'STREAM_ERROR',
          originalError: e,
        ),
      );
    }
  }

  Stream<List<ServiceRequestEnhancedModel>> streamWorkerServiceRequests(
    String workerId,
  ) {
    _ensureNotDisposed();
    _validateWorkerId(workerId);

    try {
      return firestoreService.streamWorkerServiceRequests(workerId);
    } catch (e) {
      _logError('streamWorkerServiceRequests', e);
      return Stream.error(
        ServiceRequestServiceException(
          'Failed to stream worker service requests',
          code: 'STREAM_ERROR',
          originalError: e,
        ),
      );
    }
  }

  void _validateCreateRequestInput({
    required String userId,
    required String userName,
    required String userPhone,
    required String serviceType,
    required String title,
    required String description,
    required DateTime scheduledDate,
    required double userLatitude,
    required double userLongitude,
    required String userAddress,
    required List<String> mediaUrls,
  }) {
    _validateUserId(userId);
    _validateUserName(userName);
    _validateUserPhone(userPhone);
    _validateServiceType(serviceType);
    _validateTitle(title);
    _validateDescription(description);
    _validateScheduledDate(scheduledDate);
    _validateCoordinates(userLatitude, userLongitude);
    _validateUserAddress(userAddress);
    _validateMediaUrls(mediaUrls);
  }

  void _validateServiceRequest(ServiceRequestEnhancedModel request) {
    if (request.id.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'Service request ID cannot be empty',
        code: 'INVALID_REQUEST_ID',
      );
    }
  }

  void _validateUserId(String userId) {
    if (userId.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'User ID cannot be empty',
        code: 'INVALID_USER_ID',
      );
    }
  }

  void _validateWorkerId(String workerId) {
    if (workerId.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'Worker ID cannot be empty',
        code: 'INVALID_WORKER_ID',
      );
    }
  }

  void _validateRequestId(String requestId) {
    if (requestId.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'Request ID cannot be empty',
        code: 'INVALID_REQUEST_ID',
      );
    }
  }

  void _validateUserName(String userName) {
    if (userName.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'User name cannot be empty',
        code: 'INVALID_USER_NAME',
      );
    }
  }

  void _validateUserPhone(String userPhone) {
    if (userPhone.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'User phone cannot be empty',
        code: 'INVALID_USER_PHONE',
      );
    }
  }

  void _validateServiceType(String serviceType) {
    if (serviceType.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'Service type cannot be empty',
        code: 'INVALID_SERVICE_TYPE',
      );
    }
  }

  void _validateTitle(String title) {
    final trimmed = title.trim();

    if (trimmed.isEmpty) {
      throw ServiceRequestServiceException(
        'Title cannot be empty',
        code: 'INVALID_TITLE',
      );
    }

    if (trimmed.length < minTitleLength) {
      throw ServiceRequestServiceException(
        'Title too short: ${trimmed.length} characters (min: $minTitleLength)',
        code: 'TITLE_TOO_SHORT',
      );
    }

    if (trimmed.length > maxTitleLength) {
      throw ServiceRequestServiceException(
        'Title too long: ${trimmed.length} characters (max: $maxTitleLength)',
        code: 'TITLE_TOO_LONG',
      );
    }
  }

  void _validateDescription(String description) {
    final trimmed = description.trim();

    if (trimmed.isEmpty) {
      throw ServiceRequestServiceException(
        'Description cannot be empty',
        code: 'INVALID_DESCRIPTION',
      );
    }

    if (trimmed.length < minDescriptionLength) {
      throw ServiceRequestServiceException(
        'Description too short: ${trimmed.length} characters (min: $minDescriptionLength)',
        code: 'DESCRIPTION_TOO_SHORT',
      );
    }

    if (trimmed.length > maxDescriptionLength) {
      throw ServiceRequestServiceException(
        'Description too long: ${trimmed.length} characters (max: $maxDescriptionLength)',
        code: 'DESCRIPTION_TOO_LONG',
      );
    }
  }

  void _validateScheduledDate(DateTime scheduledDate) {
    final now = DateTime.now();

    if (scheduledDate.isBefore(now.subtract(const Duration(hours: 1)))) {
      throw ServiceRequestServiceException(
        'Scheduled date cannot be in the past',
        code: 'INVALID_SCHEDULED_DATE',
      );
    }
  }

  /// [AUTO FIX] Added zero-coordinate guard (lat=0.0, lng=0.0).
  ///
  /// (0.0, 0.0) is "Null Island" in the Gulf of Guinea — the default value
  /// returned by position APIs before a real GPS fix is obtained. Submitting
  /// a request with these coordinates assigns it to the wrong wilaya and makes
  /// it invisible to workers in the client's actual location.
  void _validateCoordinates(double latitude, double longitude) {
    if (latitude == 0.0 && longitude == 0.0) {
      throw ServiceRequestServiceException(
        'Location not yet acquired. Please wait for a valid GPS fix before '
        'submitting a request.',
        code: 'LOCATION_NOT_ACQUIRED',
      );
    }

    if (latitude < -90 || latitude > 90) {
      throw ServiceRequestServiceException(
        'Invalid latitude: $latitude (must be between -90 and 90)',
        code: 'INVALID_LATITUDE',
      );
    }

    if (longitude < -180 || longitude > 180) {
      throw ServiceRequestServiceException(
        'Invalid longitude: $longitude (must be between -180 and 180)',
        code: 'INVALID_LONGITUDE',
      );
    }
  }

  void _validateUserAddress(String userAddress) {
    if (userAddress.trim().isEmpty) {
      throw ServiceRequestServiceException(
        'User address cannot be empty',
        code: 'INVALID_USER_ADDRESS',
      );
    }
  }

  void _validateMediaUrls(List<String> mediaUrls) {
    if (mediaUrls.length > maxMediaUrls) {
      throw ServiceRequestServiceException(
        'Too many media URLs: ${mediaUrls.length} (max: $maxMediaUrls)',
        code: 'TOO_MANY_MEDIA_URLS',
      );
    }

    for (final url in mediaUrls) {
      if (url.trim().isEmpty) {
        throw ServiceRequestServiceException(
          'Media URL cannot be empty',
          code: 'INVALID_MEDIA_URL',
        );
      }
    }
  }

  void _validatePrice(double price) {
    if (price < minPrice) {
      throw ServiceRequestServiceException(
        'Invalid price: $price (minimum: $minPrice)',
        code: 'INVALID_PRICE',
      );
    }

    if (price > maxPrice) {
      throw ServiceRequestServiceException(
        'Price too high: $price (maximum: $maxPrice)',
        code: 'PRICE_TOO_HIGH',
      );
    }
  }

  String _generateRequestId() {
    return const Uuid().v4();
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw ServiceRequestServiceException(
        'ServiceRequestService has been disposed',
        code: 'SERVICE_DISPOSED',
      );
    }
  }

  void _logInfo(String message) {
    if (kDebugMode) debugPrint('[ServiceRequestService] INFO: $message');
  }

  void _logWarning(String message) {
    if (kDebugMode) debugPrint('[ServiceRequestService] WARNING: $message');
  }

  void _logError(String method, dynamic error) {
    if (kDebugMode) {
      debugPrint('[ServiceRequestService] ERROR in $method: $error');
    }
  }

  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;
    _logInfo('ServiceRequestService disposed');
  }
}
