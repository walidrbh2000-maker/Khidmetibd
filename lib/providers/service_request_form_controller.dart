// lib/providers/service_request_form_controller.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../models/message_enums.dart';
import '../models/service_request_enhanced_model.dart';
import '../providers/core_providers.dart';
import '../providers/location_controller.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';
import '../../../utils/app_config.dart';
import '../../../utils/media_path_helper.dart';

// ============================================================================
// STATE
// ============================================================================

enum RequestFormStep { serviceType, details, media, schedule, location }
enum LocationDetectionStatus { idle, detecting, detected, denied, error }
enum SubmitStatus { idle, uploading, submitting, success, error }

class ServiceRequestFormState {
  final String? serviceType;
  final String title;
  final String description;
  final List<File> mediaFiles;
  final bool isEmergency;
  final DateTime scheduledDate;
  final TimeOfDay scheduledTime;
  final ServicePriority priority;
  final double? latitude;
  final double? longitude;
  final String address;
  final LocationDetectionStatus locationStatus;
  final bool isGeocodingAddress;
  final String? geocodingError;
  final SubmitStatus submitStatus;
  final String? submitErrorMessage;
  final ServiceRequestEnhancedModel? createdRequest;

  const ServiceRequestFormState({
    this.serviceType,
    this.title = '',
    this.description = '',
    this.mediaFiles = const [],
    this.isEmergency = false,
    required this.scheduledDate,
    required this.scheduledTime,
    this.priority = ServicePriority.normal,
    this.latitude,
    this.longitude,
    this.address = '',
    this.locationStatus = LocationDetectionStatus.idle,
    this.isGeocodingAddress = false,
    this.geocodingError,
    this.submitStatus = SubmitStatus.idle,
    this.submitErrorMessage,
    this.createdRequest,
  });

  bool get isServiceSelected => serviceType != null;
  bool get hasDescription => description.trim().length >= 10;
  bool get hasLocation => latitude != null && longitude != null;
  bool get canSubmit =>
      isServiceSelected && hasDescription && hasLocation && !isSubmitting;
  bool get isSubmitting =>
      submitStatus == SubmitStatus.uploading ||
      submitStatus == SubmitStatus.submitting;
  bool get isSuccess => submitStatus == SubmitStatus.success;
  int get mediaCount => mediaFiles.length;

  bool get isManualAddressRequired =>
      locationStatus == LocationDetectionStatus.denied ||
      locationStatus == LocationDetectionStatus.error;

  bool get canGeocodeAddress =>
      isManualAddressRequired &&
      address.trim().length >= 5 &&
      !isGeocodingAddress;

  // FIX (Controller-Screen Fit): `_canAdvance()` previously lived as a private
  // method inside `_ServiceRequestScreenState`, mixing business-rule logic into
  // the widget layer. The question "can the user advance from step N?" depends
  // only on form state — it belongs here as a computed getter on the state.
  //
  // `ServiceRequestScreen` now calls `state.canAdvanceStep(_currentStep)` and
  // the `_canAdvance()` screen-side method is removed entirely.
  bool canAdvanceStep(int step) {
    switch (step) {
      case 0:
        // Step 0 — service type selection: must have a type chosen.
        return serviceType != null;
      case 1:
        // Step 1 — description: minimum 10 characters required.
        return hasDescription;
      case 2:
        // Step 2 — confirm + location: full canSubmit guard.
        return canSubmit;
      default:
        return false;
    }
  }

  ServiceRequestFormState copyWith({
    String? serviceType,
    String? title,
    String? description,
    List<File>? mediaFiles,
    bool? isEmergency,
    DateTime? scheduledDate,
    TimeOfDay? scheduledTime,
    ServicePriority? priority,
    double? latitude,
    double? longitude,
    String? address,
    LocationDetectionStatus? locationStatus,
    bool? isGeocodingAddress,
    String? geocodingError,
    SubmitStatus? submitStatus,
    String? submitErrorMessage,
    ServiceRequestEnhancedModel? createdRequest,
    bool clearLocation = false,
    bool clearError = false,
    bool clearServiceType = false,
    bool clearGeocodingError = false,
  }) {
    return ServiceRequestFormState(
      serviceType: clearServiceType ? null : (serviceType ?? this.serviceType),
      title: title ?? this.title,
      description: description ?? this.description,
      mediaFiles: mediaFiles ?? this.mediaFiles,
      isEmergency: isEmergency ?? this.isEmergency,
      scheduledDate: scheduledDate ?? this.scheduledDate,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      priority: priority ?? this.priority,
      latitude: clearLocation ? null : (latitude ?? this.latitude),
      longitude: clearLocation ? null : (longitude ?? this.longitude),
      address: clearLocation ? '' : (address ?? this.address),
      locationStatus: locationStatus ?? this.locationStatus,
      isGeocodingAddress: isGeocodingAddress ?? this.isGeocodingAddress,
      geocodingError: clearGeocodingError
          ? null
          : (geocodingError ?? this.geocodingError),
      submitStatus: submitStatus ?? this.submitStatus,
      submitErrorMessage: clearError
          ? null
          : (submitErrorMessage ?? this.submitErrorMessage),
      createdRequest: createdRequest ?? this.createdRequest,
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class ServiceRequestFormController
    extends StateNotifier<ServiceRequestFormState> {
  final Ref _ref;
  final _picker = ImagePicker();
  static const int _maxMediaFiles = 5;
  static const int _maxDescriptionLength = 500;

  ServiceRequestFormController(this._ref, {bool isEmergency = false})
      : super(ServiceRequestFormState(
          scheduledDate: DateTime.now(),
          scheduledTime: TimeOfDay.now(),
          isEmergency: isEmergency,
          priority:
              isEmergency ? ServicePriority.urgent : ServicePriority.normal,
        )) {
    AppLogger.debug(
        'ServiceRequestFormController: initialized emergency=$isEmergency');
    _detectLocation();

    _ref.listen<UserLocationState>(
      userLocationControllerProvider,
      (prev, next) {
        if (!mounted) return;
        if (state.locationStatus != LocationDetectionStatus.detecting) return;

        if (next.userLocation != null) {
          AppLogger.info(
              'ServiceRequestFormController: location arrived from UserLocationController');
          _applyLocation(
              next.userLocation!.latitude, next.userLocation!.longitude);
        } else if (next.isDenied) {
          _useFallbackLocation();
        }
      },
    );
  }

  // --------------------------------------------------------------------------
  // Service Type
  // --------------------------------------------------------------------------

  void selectServiceType(String type) {
    AppLogger.debug('ServiceRequestFormController: serviceType=$type');
    state = state.copyWith(serviceType: type);
    _autoSetTitle(type);
  }

  void _autoSetTitle(String type) {
    if (state.title.isEmpty) {
      state = state.copyWith(title: type);
    }
  }

  // --------------------------------------------------------------------------
  // Description
  // --------------------------------------------------------------------------

  void setDescription(String description) {
    final trimmed = description.length > _maxDescriptionLength
        ? description.substring(0, _maxDescriptionLength)
        : description;
    state = state.copyWith(description: trimmed);
  }

  // --------------------------------------------------------------------------
  // Schedule
  // --------------------------------------------------------------------------

  void setScheduleAsap() {
    final now = DateTime.now();
    state = state.copyWith(
      scheduledDate: now,
      scheduledTime: TimeOfDay.now(),
    );
  }

  void setScheduleTodayEvening() {
    final now = DateTime.now();
    state = state.copyWith(
      scheduledDate: now,
      scheduledTime: const TimeOfDay(hour: 18, minute: 0),
    );
  }

  void setScheduleTomorrow() {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    state = state.copyWith(
      scheduledDate: tomorrow,
      scheduledTime: const TimeOfDay(hour: 9, minute: 0),
    );
  }

  void setScheduledDate(DateTime date) =>
      state = state.copyWith(scheduledDate: date);

  void setScheduledTime(TimeOfDay time) =>
      state = state.copyWith(scheduledTime: time);

  // --------------------------------------------------------------------------
  // Priority
  // --------------------------------------------------------------------------

  void setPriority(ServicePriority priority) =>
      state = state.copyWith(priority: priority);

  // --------------------------------------------------------------------------
  // Media
  // --------------------------------------------------------------------------

  Future<void> pickFromGallery() async {
    if (state.mediaFiles.length >= _maxMediaFiles) return;
    try {
      final mediaService = _ref.read(mediaServiceProvider);
      final file = await mediaService.pickImage(fromCamera: false);
      if (file != null) {
        state = state.copyWith(
            mediaFiles: [...state.mediaFiles, file]);
      }
    } catch (e) {
      AppLogger.error('ServiceRequestFormController.pickFromGallery', e);
    }
  }

  Future<void> pickFromCamera() async {
    if (state.mediaFiles.length >= _maxMediaFiles) return;
    try {
      final mediaService = _ref.read(mediaServiceProvider);
      final file = await mediaService.pickImage(fromCamera: true);
      if (file != null) {
        state = state.copyWith(
            mediaFiles: [...state.mediaFiles, file]);
      }
    } catch (e) {
      AppLogger.error('ServiceRequestFormController.pickFromCamera', e);
    }
  }

  Future<void> pickVideo() async {
    if (state.mediaFiles.length >= _maxMediaFiles) return;
    try {
      final mediaService = _ref.read(mediaServiceProvider);
      final file = await mediaService.pickVideo(fromCamera: false);
      if (file != null) {
        state = state.copyWith(
            mediaFiles: [...state.mediaFiles, file]);
      }
    } catch (e) {
      AppLogger.error('ServiceRequestFormController.pickVideo', e);
    }
  }

  void removeMedia(int index) {
    final updated = List<File>.from(state.mediaFiles)..removeAt(index);
    state = state.copyWith(mediaFiles: updated);
  }

  // --------------------------------------------------------------------------
  // Location
  // --------------------------------------------------------------------------

  Future<void> _detectLocation() async {
    if (!mounted) return;
    state = state.copyWith(locationStatus: LocationDetectionStatus.detecting);

    final locationState = _ref.read(userLocationControllerProvider);

    if (locationState.userLocation != null) {
      AppLogger.info(
          'ServiceRequestFormController: instant location from '
          'UserLocationController — '
          '${locationState.userLocation!.latitude}, '
          '${locationState.userLocation!.longitude}');
      await _applyLocation(
        locationState.userLocation!.latitude,
        locationState.userLocation!.longitude,
      );
      return;
    }

    if (locationState.isDenied) {
      AppLogger.warning(
          'ServiceRequestFormController: location denied by UserLocationController');
      _useFallbackLocation();
      return;
    }

    AppLogger.info(
        'ServiceRequestFormController: waiting for UserLocationController to resolve…');
  }

  Future<void> retryLocation() async {
    if (!mounted) return;
    state = state.copyWith(locationStatus: LocationDetectionStatus.detecting);
    await _ref.read(userLocationControllerProvider.notifier).retryLocation();
  }

  void setManualLocation({
    required double lat,
    required double lng,
    required String address,
  }) {
    state = state.copyWith(
      latitude: lat,
      longitude: lng,
      address: address,
      locationStatus: LocationDetectionStatus.detected,
    );
  }

  /// Called when the user drops the pin on the map picker.
  /// Sets coordinates immediately, then runs reverse geocoding in background.
  Future<void> setMapPickedLocation(double lat, double lng) async {
    if (!mounted) return;
    state = state.copyWith(
      latitude: lat,
      longitude: lng,
      locationStatus: LocationDetectionStatus.detected,
      isGeocodingAddress: true,
    );
    try {
      final geocodingService = _ref.read(geocodingServiceProvider);
      final address = await geocodingService.getAddressFromCoordinates(
        lat: lat,
        lng: lng,
      );
      if (!mounted) return;
      state = state.copyWith(
        address: address ?? '',
        isGeocodingAddress: false,
      );
    } catch (e) {
      AppLogger.warning(
          'ServiceRequestFormController.setMapPickedLocation: $e');
      if (!mounted) return;
      state = state.copyWith(isGeocodingAddress: false);
    }
  }

  void setAddress(String address) =>
      state = state.copyWith(address: address);

  Future<void> geocodeManualAddress(String address) async {
    final trimmed = address.trim();
    if (trimmed.length < 5 || !mounted) return;

    state = state.copyWith(
      address: trimmed,
      isGeocodingAddress: true,
      clearGeocodingError: true,
    );

    try {
      final geocodingService = _ref.read(geocodingServiceProvider);
      final coords =
          await geocodingService.getCoordinatesFromAddress(trimmed);

      if (!mounted) return;

      if (coords == null) {
        AppLogger.warning(
            'ServiceRequestFormController.geocodeManualAddress: '
            'no result for "$trimmed"');
        state = state.copyWith(
          isGeocodingAddress: false,
          geocodingError: 'address_not_found',
          clearLocation: true,
        );
        return;
      }

      state = state.copyWith(
        latitude: coords.lat,
        longitude: coords.lng,
        address: trimmed,
        locationStatus: LocationDetectionStatus.detected,
        isGeocodingAddress: false,
        clearGeocodingError: true,
      );

      AppLogger.info(
          'ServiceRequestFormController.geocodeManualAddress: '
          'resolved "$trimmed" → ${coords.lat}, ${coords.lng}');
    } catch (e) {
      AppLogger.error('ServiceRequestFormController.geocodeManualAddress', e);
      if (!mounted) return;
      state = state.copyWith(
        isGeocodingAddress: false,
        geocodingError: e.toString(),
        clearLocation: true,
      );
    }
  }

  // --------------------------------------------------------------------------
  // Private helpers
  // --------------------------------------------------------------------------

  Future<void> _applyLocation(double lat, double lng) async {
    if (!mounted) return;
    state = state.copyWith(
      latitude: lat,
      longitude: lng,
      locationStatus: LocationDetectionStatus.detected,
    );
    await _reverseGeocode(lat, lng);
  }

  void _useFallbackLocation() {
    state = state.copyWith(
      locationStatus: LocationDetectionStatus.denied,
      clearLocation: true,
    );
  }

  Future<void> _reverseGeocode(double lat, double lng) async {
    try {
      final geocodingService = _ref.read(geocodingServiceProvider);
      final address =
          await geocodingService.getAddressFromCoordinates(lat: lat, lng: lng);
      if (!mounted) return;
      if (address != null) state = state.copyWith(address: address);
    } catch (e) {
      AppLogger.warning('ServiceRequestFormController._reverseGeocode: $e');
    }
  }

  // --------------------------------------------------------------------------
  // Submit
  // --------------------------------------------------------------------------

  Future<void> submit() async {
    if (!state.canSubmit || !mounted) return;

    final user = _ref.read(currentUserProvider);
    if (user == null) {
      state = state.copyWith(
        submitStatus: SubmitStatus.error,
        submitErrorMessage: 'user_not_authenticated',
      );
      return;
    }

    final userProfile =
        await _ref.read(userProfileProvider(user.uid).future);
    state =
        state.copyWith(clearError: true, submitStatus: SubmitStatus.uploading);

    try {
      final List<String> mediaUrls = [];
      if (state.mediaFiles.isNotEmpty) {
        final mediaService = _ref.read(mediaServiceProvider);
        for (final file in state.mediaFiles) {
          final ext = file.path.split('.').last.toLowerCase();
          final isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
          final url = isVideo
              ? await mediaService.uploadVideo(file)
              : await mediaService.uploadImage(file);
          mediaUrls.add(url.storedPath);
        }
      }

      if (!mounted) return;
      state = state.copyWith(submitStatus: SubmitStatus.submitting);

      final service = _ref.read(serviceRequestServiceProvider);
      final created = await service.createServiceRequest(
        userId: user.uid,
        userName: userProfile?.name ?? user.displayName ?? 'User',
        userPhone: userProfile?.phoneNumber ?? '',
        serviceType: state.serviceType!,
        title: state.title.isNotEmpty ? state.title : state.serviceType!,
        description: state.description,
        scheduledDate: state.scheduledDate,
        scheduledTime: state.scheduledTime,
        priority: state.priority,
        userLatitude: state.latitude!,
        userLongitude: state.longitude!,
        userAddress: state.address,
        mediaUrls: mediaUrls,
      );

      AppLogger.success(
          'ServiceRequestFormController: request created ${created.id}');
      if (!mounted) return;
      state = state.copyWith(
        submitStatus: SubmitStatus.success,
        createdRequest: created,
      );
    } catch (e) {
      AppLogger.error('ServiceRequestFormController.submit', e);
      if (!mounted) return;
      state = state.copyWith(
        submitStatus: SubmitStatus.error,
        submitErrorMessage: e.toString(),
      );
    }
  }

  void resetError() => state = state.copyWith(
        submitStatus: SubmitStatus.idle,
        clearError: true,
      );
}

// ============================================================================
// PROVIDER
// ============================================================================

/// Family parameter: `isEmergency` bool
final serviceRequestFormControllerProvider = StateNotifierProvider.autoDispose
    .family<ServiceRequestFormController, ServiceRequestFormState, bool>(
  (ref, isEmergency) =>
      ServiceRequestFormController(ref, isEmergency: isEmergency),
);
