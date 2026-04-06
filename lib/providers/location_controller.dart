// lib/providers/location_controller.dart

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../utils/logger.dart';
import 'app_lifecycle_provider.dart';
import 'core_providers.dart';
import 'location_permission_controller.dart';

// ============================================================================
// STATE
// ============================================================================

enum UserLocationStatus {
  idle,
  loading,
  loaded,
  /// App permission denied (not permanently).
  denied,
  /// App permission permanently denied — user must go to Settings.
  permanentlyDenied,
  /// GPS hardware is switched off — user must enable it in device settings.
  gpsDisabled,
  error,
}

class UserLocationState {
  final UserLocationStatus status;
  final LatLng? userLocation;

  const UserLocationState({
    this.status = UserLocationStatus.idle,
    this.userLocation,
  });

  bool get isLoaded  => status == UserLocationStatus.loaded;
  bool get isLoading =>
      status == UserLocationStatus.loading ||
      status == UserLocationStatus.idle;

  bool get isDenied =>
      status == UserLocationStatus.denied ||
      status == UserLocationStatus.permanentlyDenied ||
      status == UserLocationStatus.gpsDisabled;

  bool get isGpsDisabled       => status == UserLocationStatus.gpsDisabled;
  bool get isPermanentlyDenied => status == UserLocationStatus.permanentlyDenied;

  UserLocationState copyWith({
    UserLocationStatus? status,
    LatLng? userLocation,
    bool clearLocation = false,
  }) {
    return UserLocationState(
      status:       status       ?? this.status,
      userLocation: clearLocation ? null : (userLocation ?? this.userLocation),
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class UserLocationController extends StateNotifier<UserLocationState> {
  final Ref _ref;

  StreamSubscription<Position>?      _positionStreamSub;
  StreamSubscription<ServiceStatus>? _serviceStatusSub;

  // FIX — Active GPS polling: started whenever state = gpsDisabled.
  // Solves the scenario where the user enables GPS from the Android quick-settings
  // panel WITHOUT leaving the app — in that case no AppLifecycle transition fires
  // (the notification shade does not trigger paused/resumed on most devices) and
  // Geolocator.getServiceStatusStream() is unreliable on many OEM ROMs
  // (Huawei, MIUI, ColorOS, …). Passive listeners are therefore insufficient.
  // Polling every 3 s is the only cross-device guarantee.
  Timer? _gpsPollingTimer;

  UserLocationController(this._ref) : super(const UserLocationState()) {
    _initialize();

    // Re-initialise immediately when GPS is switched back on — no polling.
    _serviceStatusSub = Geolocator.getServiceStatusStream().listen(
      (status) {
        if (!mounted) return;
        if (status == ServiceStatus.enabled) {
          AppLogger.info(
              'UserLocationController: GPS re-enabled — re-initialising');
          _stopGpsPolling();
          _initialize();
        } else {
          AppLogger.warning('UserLocationController: GPS disabled');
          state = state.copyWith(status: UserLocationStatus.gpsDisabled);
          _startGpsPolling();
        }
      },
    );

    _ref.listen<LocationPermissionState>(
      locationPermissionControllerProvider,
      (prev, next) {
        if (!mounted) return;
        final wasNotReady = !(prev?.isFullyReady ?? false);
        if (next.isFullyReady && wasNotReady) {
          AppLogger.info(
              'UserLocationController: permission + GPS now ready — retrying');
          _stopGpsPolling();
          _initialize();
        }
      },
    );

    // AppLifecycle safety-net: covers the case where the user went to the system
    // Settings app to enable GPS (app was paused → resumed).
    _ref.listen<AppLifecycleStateEnum>(
      appLifecycleProvider,
      (prev, next) {
        if (!mounted) return;
        if (next == AppLifecycleStateEnum.resumed &&
            prev != AppLifecycleStateEnum.resumed &&
            (state.status == UserLocationStatus.gpsDisabled ||
             state.status == UserLocationStatus.error)) {
          AppLogger.info(
              'UserLocationController: app resumed with recoverable state '
              '(${state.status}) — retrying');
          _stopGpsPolling();
          _initialize();
        }
      },
    );
  }

  @override
  void dispose() {
    _stopGpsPolling();
    _positionStreamSub?.cancel();
    _serviceStatusSub?.cancel();
    _ref.read(locationServiceProvider).stopPositionStream();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // Public API
  // --------------------------------------------------------------------------

  Future<void> retryLocation() => _initialize();

  // --------------------------------------------------------------------------
  // GPS polling helpers
  // --------------------------------------------------------------------------

  // Starts a 3-second periodic poll that watches for GPS to come on while the
  // controller is stuck in gpsDisabled. Cancelled as soon as GPS is detected,
  // or when _initialize() is called for any other reason.
  void _startGpsPolling() {
    // Guard: never run two pollers concurrently.
    if (_gpsPollingTimer != null) return;

    AppLogger.info('UserLocationController: starting GPS polling (3s interval)');

    _gpsPollingTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) {
        _stopGpsPolling();
        return;
      }
      // Only keep polling while we are still in gpsDisabled. If the user
      // navigated away or the state changed for any other reason, stop.
      if (state.status != UserLocationStatus.gpsDisabled) {
        _stopGpsPolling();
        return;
      }

      final locationService = _ref.read(locationServiceProvider);
      final enabled = await locationService.isLocationServiceEnabled();

      if (!mounted) { _stopGpsPolling(); return; }

      if (enabled) {
        AppLogger.info(
            'UserLocationController: GPS polling detected hardware ON — '
            'syncing permission state and re-initialising');
        _stopGpsPolling();

        // Sync LocationPermissionController so its gpsHardwareStatus flips to
        // enabled (keeps UI state consistent). autoPrompt=false — we must NOT
        // re-show the in-app dialog here; we only want a silent status refresh.
        _ref
            .read(locationPermissionControllerProvider.notifier)
            .recheck(autoPrompt: false);

        // Re-initialise directly. We do not rely solely on the isFullyReady
        // listener above because LocationPermissionController.recheck() is async
        // and the listener might not fire before we need to act.
        _initialize();
      }
    });
  }

  void _stopGpsPolling() {
    _gpsPollingTimer?.cancel();
    _gpsPollingTimer = null;
    AppLogger.info('UserLocationController: GPS polling stopped');
  }

  // --------------------------------------------------------------------------
  // Private helpers
  // --------------------------------------------------------------------------

  Future<void> _initialize() async {
    // Stop any active GPS poll — a new _initialize() call supersedes it.
    _stopGpsPolling();

    // Cancel any previous subscription before re-initialising.
    await _positionStreamSub?.cancel();
    _positionStreamSub = null;

    final locationService = _ref.read(locationServiceProvider);
    // Make sure the service stream is stopped before we restart it.
    await locationService.stopPositionStream();

    state = state.copyWith(status: UserLocationStatus.loading);

    try {
      // ── Step 0: Validate GPS hardware ─────────────────────────────────────
      // Delegated to LocationService — never call Geolocator directly here.
      final serviceEnabled = await locationService.isLocationServiceEnabled();
      if (!serviceEnabled) {
        // FIX — Race condition safety net: LocationPermissionController polls
        // isLocationServiceEnabled() before emitting GpsHardwareStatus.enabled,
        // but a residual timing window can still exist on some Android devices
        // where the OS hasn't fully propagated GPS activation by the time
        // _initialize() reaches this check. A single short-delay retry here
        // catches that remaining window and avoids a dead-end gpsDisabled state
        // that would otherwise require an app restart to recover from.
        await Future.delayed(const Duration(milliseconds: 2000));
        if (!mounted) return;
        final serviceEnabledAfterDelay =
            await locationService.isLocationServiceEnabled();
        if (!serviceEnabledAfterDelay) {
          AppLogger.warning('UserLocationController: GPS hardware disabled');
          state = state.copyWith(
            status:        UserLocationStatus.gpsDisabled,
            clearLocation: true,
          );
          _ref.read(locationPermissionControllerProvider.notifier).recheck();
          // GPS is confirmed off — start polling so we self-heal the moment the
          // user enables it (from quick-settings or system settings).
          _startGpsPolling();
          return;
        }
      }

      // ── Step 1: Validate app permission ────────────────────────────────────
      final permission = await locationService.checkPermission();
      if (permission == LocationPermission.denied) {
        AppLogger.warning(
            'UserLocationController: location permission denied');
        state = state.copyWith(
          status:        UserLocationStatus.denied,
          clearLocation: true,
        );
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        AppLogger.warning(
            'UserLocationController: location permission permanently denied');
        state = state.copyWith(
          status:        UserLocationStatus.permanentlyDenied,
          clearLocation: true,
        );
        return;
      }

      // ── Step 2: Serve cached position immediately ──────────────────────────
      final lastKnown = await locationService.getLastKnownPosition();
      if (lastKnown != null && mounted) {
        AppLogger.info(
            'UserLocationController: cached position — '
            '${lastKnown.latitude}, ${lastKnown.longitude}');
        state = state.copyWith(
          status:       UserLocationStatus.loaded,
          userLocation: LatLng(lastKnown.latitude, lastKnown.longitude),
        );
      }

      // ── Step 3: GPS stream — show FIRST position immediately, refine silently
      //
      // Previous behaviour: wait for accuracy ≤ 100m or timeout 8s → user
      // sees a spinner on first launch until GPS warms up.
      //
      // New behaviour:
      //   • First position received → shown on map immediately (even 500m acc)
      //   • Stream keeps running in background, updating silently as GPS improves
      //   • Stream stops when accuracy ≤ 30m (excellent fix) or after 30s
      //   • This makes the map feel "alive" from the first second
      await locationService.startPositionStream(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 0,
      );

      _positionStreamSub = locationService.positionStream.listen(
        (position) {
          if (!mounted) return;

          // Show the FIRST position immediately — no accuracy gate on first update
          final isFirst = state.userLocation == null ||
              state.status != UserLocationStatus.loaded;

          if (isFirst) {
            AppLogger.info(
                'UserLocationController: first fix '
                '(acc=${position.accuracy.toStringAsFixed(0)}m) — showing now');
            state = state.copyWith(
              status:       UserLocationStatus.loaded,
              userLocation: LatLng(position.latitude, position.longitude),
            );
          } else if (position.accuracy < (state.userLocation == null ? 9999 : 50)) {
            // Silent refinement — update map position as accuracy improves
            AppLogger.debug(
                'UserLocationController: refined '
                '(acc=${position.accuracy.toStringAsFixed(0)}m)');
            state = state.copyWith(
              userLocation: LatLng(position.latitude, position.longitude),
            );
          }

          // Stop stream once we have an excellent fix (≤30m)
          if (position.accuracy <= 30.0) {
            AppLogger.info('UserLocationController: excellent fix — stopping stream');
            _positionStreamSub?.cancel();
            _positionStreamSub = null;
            locationService.stopPositionStream();
          }
        },
        onError: (Object e) {
          AppLogger.error('UserLocationController stream error', e);
          // Don't crash — keep whatever position we have
        },
        cancelOnError: false,
      );

      // Auto-stop stream after 30s regardless — saves battery
      Future.delayed(const Duration(seconds: 30), () {
        if (mounted && _positionStreamSub != null) {
          AppLogger.info('UserLocationController: stream auto-stop after 30s');
          _positionStreamSub?.cancel();
          _positionStreamSub = null;
          locationService.stopPositionStream();

          // If we still have no position after 30s, show error
          if (mounted && state.userLocation == null) {
            state = state.copyWith(
              status:        UserLocationStatus.error,
              clearLocation: true,
            );
          }
        }
      });
    } catch (e) {
      AppLogger.error('UserLocationController._initialize', e);
      await _positionStreamSub?.cancel();
      _positionStreamSub = null;
      await _ref.read(locationServiceProvider).stopPositionStream();
      if (!mounted) return;
      if (state.userLocation == null) {
        state = state.copyWith(
          status:        UserLocationStatus.error,
          clearLocation: true,
        );
      } else {
        state = state.copyWith(status: UserLocationStatus.loaded);
      }
    }
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final userLocationControllerProvider = StateNotifierProvider.autoDispose<
    UserLocationController, UserLocationState>(
  (ref) {
    final link = ref.keepAlive();
    ref.listen<bool>(isLoggedInProvider, (_, isLoggedIn) {
      if (!isLoggedIn) link.close();
    });
    return UserLocationController(ref);
  },
);
