// lib/providers/location_permission_controller.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../utils/logger.dart';
import 'app_lifecycle_provider.dart';
import 'core_providers.dart';

// ============================================================================
// ENUMS
// ============================================================================

enum LocationPermissionStatus {
  checking,
  granted,
  notDetermined,
  permanentlyDenied,
  skipped,
}

enum GpsHardwareStatus {
  checking,
  enabled,
  /// GPS is off AND the in-app dialog has already been shown this session.
  /// Prevents the dialog from looping on every recheck.
  disabledDialogShown,
  disabled,
}

// ============================================================================
// STATE
// ============================================================================

class LocationPermissionState {
  final LocationPermissionStatus permissionStatus;
  final GpsHardwareStatus gpsHardwareStatus;
  final bool isRequesting;

  const LocationPermissionState({
    this.permissionStatus = LocationPermissionStatus.checking,
    this.gpsHardwareStatus = GpsHardwareStatus.checking,
    this.isRequesting = false,
  });

  /// True only when BOTH the app permission is granted AND GPS hardware is on.
  bool get isFullyReady =>
      permissionStatus == LocationPermissionStatus.granted &&
      gpsHardwareStatus == GpsHardwareStatus.enabled;

  bool get isGranted => permissionStatus == LocationPermissionStatus.granted;

  bool get isGpsHardwareEnabled =>
      gpsHardwareStatus == GpsHardwareStatus.enabled;

  bool get isGpsHardwareDisabled =>
      gpsHardwareStatus == GpsHardwareStatus.disabled ||
      gpsHardwareStatus == GpsHardwareStatus.disabledDialogShown;

  bool get needsSettings =>
      permissionStatus == LocationPermissionStatus.permanentlyDenied;

  bool get canRequest =>
      permissionStatus == LocationPermissionStatus.notDetermined ||
      permissionStatus == LocationPermissionStatus.skipped;

  bool get isChecking =>
      permissionStatus == LocationPermissionStatus.checking ||
      gpsHardwareStatus == GpsHardwareStatus.checking;

  bool get isSkipped => permissionStatus == LocationPermissionStatus.skipped;

  LocationPermissionState copyWith({
    LocationPermissionStatus? permissionStatus,
    GpsHardwareStatus? gpsHardwareStatus,
    bool? isRequesting,
  }) {
    return LocationPermissionState(
      permissionStatus:  permissionStatus  ?? this.permissionStatus,
      gpsHardwareStatus: gpsHardwareStatus ?? this.gpsHardwareStatus,
      isRequesting:      isRequesting      ?? this.isRequesting,
    );
  }
}

// ============================================================================
// CONTROLLER
// ============================================================================

class LocationPermissionController
    extends StateNotifier<LocationPermissionState> {
  final Ref _ref;

  LocationPermissionController(this._ref)
      : super(const LocationPermissionState()) {
    // On init: check permission first, then auto-prompt GPS if already granted.
    _checkAll(autoPrompt: true);

    // AppLifecycle binding: silently re-check GPS hardware status every time the
    // app comes back to the foreground (e.g. user went to system Settings app to
    // enable GPS). autoPrompt=false — never re-show the in-app dialog on resume.
    // If GPS is now on, gpsHardwareStatus flips to enabled → isFullyReady → true
    // → UserLocationController's permission listener fires → _initialize() runs.
    _ref.listen<AppLifecycleStateEnum>(
      appLifecycleProvider,
      (prev, next) {
        if (!mounted) return;
        if (next == AppLifecycleStateEnum.resumed &&
            prev != AppLifecycleStateEnum.resumed) {
          AppLogger.info(
              'LocationPermissionController: app resumed — rechecking GPS status');
          recheck(autoPrompt: false);
        }
      },
    );
  }

  // --------------------------------------------------------------------------
  // Public API
  // --------------------------------------------------------------------------

  /// Requests the app location permission through the OS system dialog.
  Future<void> requestPermission() async {
    if (state.isRequesting) return;
    state = state.copyWith(isRequesting: true);

    try {
      final permService = _ref.read(permissionServiceProvider);
      final granted = await permService.requestLocationPermission();

      if (!mounted) return;

      if (granted) {
        AppLogger.info('LocationPermissionController: permission granted');
        state = state.copyWith(
          permissionStatus: LocationPermissionStatus.granted,
          isRequesting:     false,
        );
        // Permission just granted — immediately show GPS dialog if hardware off.
        await _checkAndRequestGps(autoPrompt: true);
      } else {
        final isPermanent = await permService.isPermissionPermanentlyDenied(
          ph.Permission.location,
        );
        if (!mounted) return;
        state = state.copyWith(
          permissionStatus: isPermanent
              ? LocationPermissionStatus.permanentlyDenied
              : LocationPermissionStatus.notDetermined,
          isRequesting: false,
        );
        AppLogger.warning(
            'LocationPermissionController: denied (permanent=$isPermanent)');
      }
    } catch (e) {
      AppLogger.error('LocationPermissionController.requestPermission', e);
      if (mounted) {
        state = state.copyWith(
          permissionStatus: LocationPermissionStatus.notDetermined,
          isRequesting:     false,
        );
      }
    }
  }

  /// Opens the OS app-settings page (for permanently-denied permission).
  Future<void> openSettings() async {
    try {
      await ph.openAppSettings();
      await Future.delayed(const Duration(milliseconds: 800));
      await _checkAll(autoPrompt: true);
    } catch (e) {
      AppLogger.error('LocationPermissionController.openSettings', e);
    }
  }

  void dismiss() {
    state = state.copyWith(permissionStatus: LocationPermissionStatus.skipped);
    AppLogger.info('LocationPermissionController: user skipped overlay');
  }

  void triggerIfSkipped() {
    if (state.isSkipped) {
      state = state.copyWith(
          permissionStatus: LocationPermissionStatus.notDetermined);
    }
  }

  /// Full recheck. [autoPrompt] = true re-shows the in-app GPS dialog if needed.
  Future<void> recheck({bool autoPrompt = false}) =>
      _checkAll(autoPrompt: autoPrompt);

  // --------------------------------------------------------------------------
  // Private helpers
  // --------------------------------------------------------------------------

  Future<void> _checkAll({bool autoPrompt = false}) async {
    await _checkPermission();
    // Only auto-prompt GPS when app permission is already granted.
    await _checkAndRequestGps(autoPrompt: autoPrompt && state.isGranted);
  }

  Future<void> _checkPermission() async {
    try {
      final permService = _ref.read(permissionServiceProvider);
      final rawStatus =
          await permService.getPermissionStatus(ph.Permission.location);

      if (!mounted) return;

      LocationPermissionStatus next;
      if (rawStatus.isGranted || rawStatus.isLimited) {
        next = LocationPermissionStatus.granted;
      } else if (rawStatus.isPermanentlyDenied) {
        next = LocationPermissionStatus.permanentlyDenied;
      } else {
        next = state.permissionStatus == LocationPermissionStatus.skipped
            ? LocationPermissionStatus.skipped
            : LocationPermissionStatus.notDetermined;
      }

      state = state.copyWith(permissionStatus: next, isRequesting: false);
      AppLogger.info(
          'LocationPermissionController: permission → ${state.permissionStatus}');
    } catch (e) {
      AppLogger.error('LocationPermissionController._checkPermission', e);
      if (mounted) {
        state = state.copyWith(
          permissionStatus: LocationPermissionStatus.notDetermined,
          isRequesting:     false,
        );
      }
    }
  }

  /// Checks GPS hardware and — when [autoPrompt] is true and GPS is off —
  /// immediately shows the Google in-app location-accuracy dialog (Image 2)
  /// via [LocationService.requestLocationService()].
  ///
  /// The dialog is shown at most **once per controller lifecycle** to avoid
  /// showing it in an infinite loop if the user keeps dismissing it.
  Future<void> _checkAndRequestGps({bool autoPrompt = false}) async {
    try {
      final locationService = _ref.read(locationServiceProvider);
      final enabled = await locationService.isLocationServiceEnabled();

      if (!mounted) return;

      if (enabled) {
        state = state.copyWith(gpsHardwareStatus: GpsHardwareStatus.enabled);
        AppLogger.info(
            'LocationPermissionController: GPS hardware → enabled');
        return;
      }

      // GPS is off — decide whether to show the in-app dialog.
      final alreadyPrompted =
          state.gpsHardwareStatus == GpsHardwareStatus.disabledDialogShown;

      if (autoPrompt && !alreadyPrompted) {
        // Mark BEFORE awaiting so parallel calls don't fire the dialog twice.
        state = state.copyWith(
            gpsHardwareStatus: GpsHardwareStatus.disabledDialogShown);

        AppLogger.info(
            'LocationPermissionController: GPS off — showing in-app dialog');

        // ── THIS produces the Image-2 "Activer" dialog ───────────────────────
        final userEnabled = await locationService.requestLocationService();

        if (!mounted) return;

        if (userEnabled) {
          // FIX — Race condition: the OS dialog returns true before Android has
          // finished activating the GPS hardware. Polling here ensures we only
          // emit GpsHardwareStatus.enabled once the hardware is genuinely on,
          // preventing UserLocationController from running _initialize() against
          // a GPS that still reports as disabled (which causes a dead-end
          // gpsDisabled state that never self-heals without an app restart).
          //
          // Poll isLocationServiceEnabled() every 500 ms for up to 3 s.
          bool hardwareConfirmed = false;
          for (int i = 0; i < 6; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (!mounted) return;
            hardwareConfirmed =
                await locationService.isLocationServiceEnabled();
            if (hardwareConfirmed) break;
          }

          AppLogger.info(
              'LocationPermissionController: user enabled GPS via dialog ✓ '
              '(hardwareConfirmed=$hardwareConfirmed)');
          state = state.copyWith(
            gpsHardwareStatus: hardwareConfirmed
                ? GpsHardwareStatus.enabled
                : GpsHardwareStatus.disabledDialogShown,
          );
        } else {
          AppLogger.warning(
              'LocationPermissionController: user dismissed GPS dialog');
          // Keep disabledDialogShown so we do NOT show the dialog again
          // unless the controller is fully re-created (sign-out / sign-in).
          state = state.copyWith(
              gpsHardwareStatus: GpsHardwareStatus.disabledDialogShown);
        }
      } else {
        // Either autoPrompt=false or dialog already shown — just update status.
        state = state.copyWith(
          gpsHardwareStatus: alreadyPrompted
              ? GpsHardwareStatus.disabledDialogShown
              : GpsHardwareStatus.disabled,
        );
        AppLogger.warning(
            'LocationPermissionController: GPS hardware → disabled '
            '(autoPrompt=$autoPrompt, alreadyPrompted=$alreadyPrompted)');
      }
    } catch (e) {
      AppLogger.error(
          'LocationPermissionController._checkAndRequestGps', e);
      if (mounted) {
        state =
            state.copyWith(gpsHardwareStatus: GpsHardwareStatus.disabled);
      }
    }
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final locationPermissionControllerProvider =
    StateNotifierProvider.autoDispose<LocationPermissionController,
        LocationPermissionState>(
  (ref) {
    final link = ref.keepAlive();
    ref.listen<bool>(isLoggedInProvider, (_, isLoggedIn) {
      if (!isLoggedIn) link.close();
    });
    return LocationPermissionController(ref);
  },
);
