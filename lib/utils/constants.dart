// lib/utils/constants.dart
//
// CHANGES (Cleanliness §7 — Dead Code):
//   • 7 dead AppRoutes constants removed:
//       messages, workerMessages, chat, mediaViewer, becomeWorker,
//       serviceRequestDetails, workerHome
//     (none of these are registered in app_router.dart)
//   • AppIcons.info2 removed — duplicate of AppIcons.info, both mapped to
//     Icons.info_outline_rounded. Dead code.
//
// CHANGES (UI Manual Pass):
//   • toggleTrackW / toggleTrackH / toggleThumbSize added — back the
//     HomeWorkerSection _ToggleSwitch raw literals (40×20 track, 16dp thumb).
//   • statusDotSize added — backs the 8dp status indicator dot in
//     _AvailabilityToggle.
//   • locationDotSize added — backs the PulsingLocationDot core diameter,
//     promoted from off-grid 14dp to the nearest on-grid value 16dp.
//
// CHANGES (UI-APPLY pass — manual items):
//   • splashLogoSize (248.0) added.
//   • splashStatusAreaHeight (64.0) added.
//   • iconSizeHero (80.0) added.
//   • splashErrorCircleSize (200.0) added.
//
// CHANGES (ui-apply W9 / W10):
//   • cardRadius = 20.0 REMOVED — duplicate of radiusCard (20.0).
//   • sectionMT: 22.0 → 24.0 (snapped to 8dp grid).
//   • navPillPaddingV: 7.0 → 8.0 (snapped to 4dp grid).
//   • chipPaddingV: 5.0 → 4.0 (snapped to 4dp grid).
//   • locationDotMarker: 38.0 → 40.0 (snapped to 8dp grid).
//
// CHANGES (ui-apply AUTO W3 / MANUAL):
//   • splashRetryButtonMinWidth (120.0) added.
//   • AppAssets.splashStatic added.
//
// CHANGES (settings ui-apply):
//   [C12] iconSizeLg2 = 64.0 — mid-scale icon between iconSizeXl (48) and
//         iconSizeHero (80); used for in-content error state icons.
//   [W5]  emojiIconSize = 22.0 — flag/icon size in SheetOption rows.
//   [W6]  tileHeight = 64.0 — canonical height for SettingsTile,
//         SignOutTile, and _DeleteAccountTile rows.
//   [W8]  settingsRetryButtonWidth = 180.0 — replaces the arithmetic
//         splashRetryButtonMinWidth * 1.5 in SettingsErrorView.
//   [W2/W3] Opacity tokens for state-conditional destructive tiles.
//         These are runtime .withValues() calls — they cannot be const-baked
//         because the base color is caller-resolved (signOutRed, error scheme).
//         Named constants replace magic literals and document each level's intent.
//
// CHANGES (settings ui-apply — AUTO pass, sheet_option.dart tokens):
//   [W1-AUTO] 5 opacity constants added for SheetOption — replaces 5 raw float
//         literals that bypassed the opacity token system.
//         opacitySheetFillDark / opacitySheetFillLight — selection highlight fill
//         opacitySheetBorderSel — selected option border alpha
//         opacitySheetBorderUnsel — unselected option border alpha
//         opacitySheetIconMuted — unselected icon colour alpha
//   [S2-AUTO] profileCardSkeletonHeight = 110.0 — promotes the magic height
//         literal in _ProfileCardSkeleton to a named token. Skeleton height
//         will no longer silently diverge if ProfileCard content grows.
//   [W1-AUTO-SPLIT] opacityDeleteTileFillDarkEn = 0.08 added as an alias that
//         makes the dual-usage of opacityTileFillLightEn explicit. Both resolve
//         to the same design value today; the separate token documents intent and
//         prevents silent breakage if the two contexts ever diverge.
//
// CHANGES (settings ui-apply — MANUAL pass):
//   [M1] borderWidthDefault = 1.0 — standard tile / option border stroke.
//        Backs the unselected SheetOption border and any future standard border.
//   [M2] borderWidthSelected = 1.5 — selected-state emphasis border stroke.
//        Backs the selected SheetOption border.
//   [M3] animDurationMicro = Duration(milliseconds: 200) — short micro-interaction
//        duration used in SheetOption AnimatedContainer. Replaces the bare
//        Duration(milliseconds: 200) magic literal.
//
// CHANGES (auth ui-apply — H2/A1/C3):
//   [H2]  buttonFontSize = 15.0 — tokenises the raw 15 literal in
//         auth_submit_button.dart and both elevatedButton theme textStyles.
//   [A1]  authCardEntranceDuration = Duration(milliseconds: 900) — the
//         reference entrance animation duration from register_screen.dart,
//         applied to email_verification_screen.dart (was 700ms).
//   [C3]  spinnerSizeLg = 20.0 — large CircularProgressIndicator dimension
//         used across primary action buttons.
//         spinnerSizeSm = 14.0 — small spinner used in secondary / text buttons.
//   [A1]  iconContainerFeature = 56.0 — feature icon container size used in
//         email_verification_screen (was hardcoded width:56, height:56).
//         Designer sign-off pending: keep 56dp or align to 48/64?
//
// CHANGES (auth ui-apply — MANUAL pass, dimension tokens):
//   logoOrbSize = 64.0 — login header logo orb container (raw 64 literals).
//   logoOrbIconSize = 30.0 — icon inside login logo orb (off-grid 30dp; pending
//       designer sign-off: 32dp would snap to grid).
//   socialButtonSize = 52.0 — CircularSocialButton width/height (raw 52 literals).
//   socialSpinnerSize = 18.0 — loading spinner inside social button (was 18dp;
//       note: sits between spinnerSizeSm=14 and spinnerSizeLg=20, not on grid).
//   roleToggleHeight = 56.0 — RegisterRoleSelector toggle container height.
//   strengthBarHeight = 3.0 — password strength segment bar height.
//   strengthBarGap = 3.0 — gap between password strength segments.
//   strengthBarRadius = 2.0 — border radius of strength bar segments
//       (nearest token radiusXs=4; kept at 2 pending designer sign-off).
//   accentShadowOpacity = 0.35 — opacity used for accent-coloured box shadows.
//   goodPasswordLength = 10 — threshold above minPasswordLength (6) used in the
//       strength scorer to award the "good length" bonus point.
//   lineHeightTight = 1.4 — tighter line-height used in dense inline text
//       (e.g. _LockoutWidget body). Standard body uses 1.6 in the textTheme.
//
// CHANGES (ui-apply pass — checkbox / role tab tokens):
//   roleTabIconSize = 18.0 — icon size in RegisterRoleSelector tabs.
//       Pending designer sign-off: 18dp sits between iconSizeXs (16) and
//       iconSizeSm (20).
//   checkboxSize = 22.0 — RegisterTermsCheckbox container size.
//       TODO: confirm 20dp or 24dp (22dp is off the 4dp grid).
//   checkboxIconSize = 14.0 — check icon size inside checkbox container.
//   checkboxRadius = 6.0 — border radius of checkbox container.
//
// TODO(S3-grid-audit): spacingTileInner (14dp), badgePaddingV (3dp), and
//   spacingXxs (2dp) are off the 4dp grid. No immediate visual regression —
//   schedule for next design-system alignment pass with designer sign-off.

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

class AppConstants {
  AppConstants._();

  static const String appName    = 'Khidmeti';
  static const String appVersion = '1.0.0';
  static const String appTagline = 'خدمات منزلية احترافية';
  static const String baseUrl    = 'https://api.khidmeti.com';

  static const int defaultPageSize = 20;
  static const int maxPageSize     = 100;

  static const double fabClearance = 80.0;
  static const double maxBidPrice  = 500000.0;

  static const Duration defaultTimeout  = Duration(seconds: 30);
  static const Duration longTimeout     = Duration(minutes: 2);
  static const Duration cacheExpiry     = Duration(hours: 1);

  /// Micro-interaction animation duration — short state transitions such as
  /// the SheetOption AnimatedContainer selection highlight.
  /// [M3]: promotes the raw Duration(milliseconds: 200) magic literal.
  static const Duration animDurationMicro = Duration(milliseconds: 200);

  /// Auth card entrance animation duration — card fade/slide in from off-screen.
  /// [A1]: reference implementation is register_screen.dart (900ms).
  /// Applied to email_verification_screen.dart (was 700ms — inconsistent).
  static const Duration authCardEntranceDuration = Duration(milliseconds: 900);

  static const int biddingDeadlineMinutes  = 120;
  static const int maxPendingBidsPerWorker = 5;

  // Spacing
  // TODO(S3-grid-audit): spacingXxs (2dp) is off the 4dp grid — designer sign-off required.
  static const double spacingXxs  = 2.0;
  static const double spacingXs   = 4.0;
  static const double spacingSm   = 8.0;
  static const double spacingMd   = 16.0;
  static const double spacingLg   = 24.0;
  static const double spacingXl   = 32.0;
  static const double spacingMdLg = 20.0;

  // [UI-FIX] 12dp gap token — used in HomeServiceGrid chip separators.
  // Sits between spacingSm (8) and spacingMd (16); deliberate design gap.
  static const double spacingChipGap = 12.0;

  // Padding
  static const double paddingXs = 4.0;
  static const double paddingSm = 8.0;
  static const double paddingMd = 16.0;
  static const double paddingLg = 24.0;
  static const double paddingXl = 32.0;

  // Radius
  static const double radiusXs     = 4.0;
  static const double radiusSm     = 8.0;
  static const double radiusMd     = 12.0;
  static const double radiusLg     = 16.0;
  static const double radiusXl     = 20.0;
  static const double radiusXxl    = 24.0;
  static const double radiusCircle = 28.0;
  static const double radiusCard   = 20.0;
  static const double radiusTile   = 18.0;

  // Buttons
  static const double buttonHeight   = 54.0;
  static const double buttonHeightMd = 48.0;
  static const double buttonHeightSm = 44.0;

  /// Canonical button label font size.
  /// [H2]: tokenises the raw literal 15 in auth_submit_button.dart and
  /// elevatedButtonTheme textStyles in app_theme.dart.
  static const double buttonFontSize = 15.0;

  // Cards
  static const double cardPadding     = 18.0;
  static const double cardBorderWidth = 0.5;
  static const double accentBarWidth  = 3.0;

  // [MANUAL FIX]: gap between a circular icon and its label in grid chips.
  static const double cardIconLabelGap = 8.0;

  // Inputs
  static const double inputRadius   = 14.0;
  static const double inputPaddingH = 18.0;
  static const double inputPaddingV = 15.0;

  // Navigation bar
  static const double navBarRadius    = 24.0;
  static const double navBarHeight    = 68.0;
  static const double navBarMarginH   = 16.0;
  static const double navBarMarginB   = 10.0;
  static const double navPillPaddingH = 14.0;
  static const double navPillPaddingV = 8.0;
  static const double navDotSize      = 4.0;

  // Hero
  static const double heroPaddingTop    = 38.0;
  static const double heroPaddingH      = 24.0;
  static const double heroPaddingBottom = 30.0;

  // Sections
  static const double sectionLabelMB = 12.0;
  static const double sectionMT      = 24.0;
  static const double sectionCardGap = 10.0;

  // Badges / chips / tile gaps
  // TODO(S3-grid-audit): spacingTileInner (14dp) and badgePaddingV (3dp) are
  //   off the 4dp grid — schedule for next design-system alignment pass.
  static const double spacingTileInner = 14.0;
  static const double badgePaddingH    = 10.0;
  static const double badgePaddingV    = 3.0;
  static const double chipRadius       = 8.0;
  static const double chipPaddingH     = 10.0;
  static const double chipPaddingV     = 4.0;

  // ── Border widths ─────────────────────────────────────────────────────────
  /// Standard tile / option border stroke (unselected state).
  static const double borderWidthDefault  = 1.0;

  /// Selected-state emphasis border stroke.
  static const double borderWidthSelected = 1.5;

  // Wordmark
  static const double wordmarkDotSize  = 8.0;
  static const double wordmarkDotBlur  = 10.0;
  static const double wordmarkFontSize = 13.0;

  // Font sizes
  static const double heroFontSize    = 32.0;
  static const double fontSizeTileLg  = 15.0;
  static const double fontSizeXxs     = 11.0;
  static const double fontSizeXs      = 10.0;
  static const double fontSizeSm      = 12.0;
  static const double fontSizeCaption = 13.0;
  static const double fontSizeMd      = 14.0;
  static const double fontSizeLg      = 16.0;
  static const double fontSizeXl      = 18.0;
  static const double fontSizeXxl     = 20.0;
  static const double fontSizeDisplay = 24.0;

  // Line heights
  /// Tight line-height for dense inline text (e.g. lockout banner body).
  /// Standard body line-height is 1.6 in the textTheme.
  static const double lineHeightTight = 1.4;

  // Icons
  static const double iconSizeXs = 16.0;
  static const double iconSizeSm = 20.0;
  static const double iconSizeMd = 24.0;
  static const double iconSizeLg = 32.0;
  static const double iconSizeXl = 48.0;

  /// Mid-scale icon token between iconSizeXl (48) and iconSizeHero (80).
  static const double iconSizeLg2 = 64.0;

  /// Hero-scale icon used in full-screen state illustrations.
  static const double iconSizeHero = 80.0;

  // Container sizes
  static const double iconContainerSm  = 28.0;
  static const double iconContainerMd  = 32.0;
  static const double iconContainerLg  = 36.0;
  static const double iconContainerXl  = 40.0;
  static const double buttonIconSize   = 20.0;

  /// Feature icon container — circular container wrapping a content icon.
  static const double iconContainerFeature = 56.0;

  /// Emoji / flag icon size used in SheetOption rows.
  static const double emojiIconSize = 22.0;

  /// Large spinner size — primary action button CircularProgressIndicator.
  static const double spinnerSizeLg = 20.0;

  /// Small spinner size — secondary / text button CircularProgressIndicator.
  static const double spinnerSizeSm = 14.0;

  // ── Auth UI tokens ────────────────────────────────────────────────────────

  /// Login header logo orb container size (width = height).
  /// Pending designer sign-off: 64dp diverges from iconContainerFeature (56dp).
  static const double logoOrbSize = 64.0;

  /// Icon size inside the login logo orb.
  /// Note: 30dp is off the 20/24/32 icon scale — designer sign-off pending.
  static const double logoOrbIconSize = 30.0;

  /// CircularSocialButton width and height.
  static const double socialButtonSize = 52.0;

  /// Loading spinner inside CircularSocialButton.
  /// Note: 18dp sits between spinnerSizeSm (14) and spinnerSizeLg (20).
  static const double socialSpinnerSize = 18.0;

  /// RegisterRoleSelector toggle container height.
  static const double roleToggleHeight = 56.0;

  /// Password strength bar segment height.
  /// Note: 3dp is off the 4dp grid — designer sign-off pending.
  static const double strengthBarHeight = 3.0;

  /// Gap between password strength bar segments.
  /// Note: 3dp is off the 4dp grid — designer sign-off pending.
  static const double strengthBarGap = 3.0;

  /// Border radius of password strength bar segments.
  /// Note: 2dp; nearest token is radiusXs (4dp) — designer sign-off pending.
  static const double strengthBarRadius = 2.0;

  // ── Checkbox / role tab tokens ────────────────────────────────────────────

  /// Icon size in RegisterRoleSelector tabs.
  /// Pending designer sign-off: 18dp sits between iconSizeXs (16) and
  /// iconSizeSm (20) — confirm intended value before token is published.
  static const double roleTabIconSize = 18.0;

  /// Checkbox container size (width = height).
  /// TODO: designer sign-off — confirm 20dp or 24dp (current 22dp is off-grid).
  static const double checkboxSize = 22.0;

  /// Check icon size inside the checkbox container.
  static const double checkboxIconSize = 14.0;

  /// Border radius of the checkbox container.
  /// Note: 6dp sits between radiusXs (4) and radiusSm (8).
  static const double checkboxRadius = 6.0;

  /// Opacity applied to accent-coloured box shadows (e.g. logo orb, submit button).
  static const double accentShadowOpacity = 0.35;

  /// Password length threshold above [minPasswordLength] that awards the
  /// "good length" bonus point in the strength scorer.
  static const int goodPasswordLength = 10;

  static const double filterChipHeight   = 36.0;
  static const double filterChipPaddingV = 8.0;
  static const double locationDotMarker  = 40.0;
  static const int    maxEmailLength     = 254;

  // Sheet handle
  static const double sheetHandleWidth  = 40.0;
  static const double sheetHandleHeight = 4.0;

  static const int fallbackWorkerQueryLimit = 100;

  // Search / input
  static const double searchBarHeight      = 44.0;
  static const double categoryTileIconSize = 48.0;

  /// Canonical row height for SettingsTile, SignOutTile, _DeleteAccountTile.
  static const double tileHeight = 64.0;

  /// Width of the retry button in SettingsErrorView.
  static const double settingsRetryButtonWidth = 180.0;

  /// Height of the ProfileCard shimmer skeleton in _ProfileCardSkeleton.
  static const double profileCardSkeletonHeight = 110.0;

  // ── Toggle switch ─────────────────────────────────────────────────────────
  static const double toggleTrackW    = 40.0;
  static const double toggleTrackH    = 20.0;
  static const double toggleThumbSize = 16.0;
  static const double statusDotSize   =  8.0;

  // ── Map / location ────────────────────────────────────────────────────────
  static const double locationDotSize = 16.0;

  // ── Splash screen ─────────────────────────────────────────────────────────
  static const double splashLogoSize            = 248.0;
  static const double splashStatusAreaHeight    = 64.0;
  static const double splashErrorCircleSize     = 200.0;
  static const double splashRetryButtonMinWidth = 120.0;

  // ── Opacity tokens — state-conditional destructive tiles ─────────────────
  static const double opacityDisabledColor    = 0.40;
  static const double opacityChevron          = 0.50;
  static const double opacityTileFillDisabled = 0.04;
  static const double opacityTileFillDarkEn   = 0.12;
  static const double opacityTileFillLightEn  = 0.08;
  static const double opacityDeleteTileFillDarkEn = 0.08;
  static const double opacityDeleteFillLightEn = 0.05;
  static const double opacityDeleteFillDis     = 0.03;
  static const double opacityIconBg            = 0.12;
  static const double opacityIconBgAlt         = 0.15;
  static const double opacityBorderEnabled     = 0.20;
  static const double opacityBorderDisabled    = 0.08;
  static const double opacityDeleteBorderDis   = 0.06;

  // ── Opacity tokens — SheetOption ─────────────────────────────────────────
  static const double opacitySheetFillDark    = 0.20;
  static const double opacitySheetFillLight   = 0.10;
  static const double opacitySheetBorderSel   = 0.50;
  static const double opacitySheetBorderUnsel = 0.20;
  static const double opacitySheetIconMuted   = 0.60;

  // Location & map
  static const double defaultSearchRadiusKm = 50.0;
  static const double minSearchRadiusKm     = 5.0;
  static const double maxSearchRadiusKm     = 100.0;
  static const String osmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const double defaultZoom = 12.0;
  static const double minZoom     = 8.0;
  static const double maxZoom     = 18.0;

  static const Map<String, LatLng> cityCenters = {
    'alger':       LatLng(36.7372, 3.0865),
    'oran':        LatLng(35.7089, -0.6416),
    'constantine': LatLng(36.3650, 6.6147),
    'annaba':      LatLng(36.9000, 7.7667),
    'blida':       LatLng(36.4203, 2.8277),
    'batna':       LatLng(35.5559, 6.1741),
    'djelfa':      LatLng(34.6792, 3.2550),
    'setif':       LatLng(36.1905, 5.4033),
  };

  // File upload
  static const int maxImageSizeMB = 10;
  static const int maxVideoSizeMB = 100;
  static const int maxAudioSizeMB = 50;

  // Validation
  static const int minPasswordLength = 6;
  static const int maxPasswordLength = 128;
  static const int minUsernameLength = 2;
  static const int maxUsernameLength = 50;

  static final RegExp emailRegex = RegExp(
    r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
  );
}

class AppAssets {
  AppAssets._();

  static const String _images     = 'assets/images';
  static const String _animations = 'assets/animations';

  static const String logo                = '$_images/logo.png';
  static const String logoWhite           = '$_images/logo_white.png';
  static const String logoIcon            = '$_images/logo_icon.png';
  static const String onboarding1         = '$_images/onboarding_1.png';
  static const String onboarding2         = '$_images/onboarding_2.png';
  static const String onboarding3         = '$_images/onboarding_3.png';
  static const String emptyRequests       = '$_images/empty_requests.png';
  static const String emptyMessages       = '$_images/empty_messages.png';
  static const String emptyWorkers        = '$_images/empty_workers.png';
  static const String noResults           = '$_images/no_results.png';
  static const String workerIllustration  = '$_images/worker.png';
  static const String userIllustration    = '$_images/user.png';
  static const String serviceIllustration = '$_images/service.png';
  static const String avatarPlaceholder   = '$_images/avatar_placeholder.png';
  static const String imagePlaceholder    = '$_images/image_placeholder.png';
  static const String loadingAnimation    = '$_animations/loading.json';
  static const String successAnimation    = '$_animations/success.json';
  static const String errorAnimation      = '$_animations/error.json';
  static const String locationAnimation   = '$_animations/location.json';
  static const String homeBoilerCare      = '$_animations/home_boiler_care.json';
  static const String splashStatic        = 'assets/splash_static.png';
}

class AppIcons {
  AppIcons._();

  // Navigation
  static const IconData home             = Icons.home_rounded;
  static const IconData homeOutlined     = Icons.home_outlined;
  static const IconData search           = Icons.search_rounded;
  static const IconData searchOutlined   = Icons.search_outlined;
  static const IconData requests         = Icons.request_page_rounded;
  static const IconData requestsOutlined = Icons.request_page_outlined;
  static const IconData messages         = Icons.message_rounded;
  static const IconData messagesOutlined = Icons.message_outlined;
  static const IconData profile          = Icons.person_rounded;
  static const IconData profileOutlined  = Icons.person_outline_rounded;

  // Worker navigation
  static const IconData dashboard         = Icons.dashboard_rounded;
  static const IconData dashboardOutlined = Icons.dashboard_outlined;
  static const IconData jobs              = Icons.work_rounded;
  static const IconData jobsOutlined      = Icons.work_outline_rounded;

  // Auth
  static const IconData email         = Icons.email_outlined;
  static const IconData password      = Icons.lock_outline_rounded;
  static const IconData visibility    = Icons.visibility_outlined;
  static const IconData visibilityOff = Icons.visibility_off_outlined;
  static const IconData person        = Icons.person_outline_rounded;
  static const IconData phone         = Icons.phone_outlined;

  // Services
  static const IconData plumbing        = Icons.plumbing_rounded;
  static const IconData electrical      = Icons.electrical_services_rounded;
  static const IconData cleaning        = Icons.cleaning_services_rounded;
  static const IconData painting        = Icons.format_paint_rounded;
  static const IconData carpentry       = Icons.carpenter_rounded;
  static const IconData gardening       = Icons.grass_rounded;
  static const IconData airConditioning = Icons.air_rounded;
  static const IconData appliances      = Icons.kitchen_rounded;

  // Actions
  static const IconData add      = Icons.add_rounded;
  static const IconData edit     = Icons.edit_rounded;
  static const IconData delete   = Icons.delete_outline_rounded;
  static const IconData save     = Icons.save_rounded;
  static const IconData cancel   = Icons.cancel_outlined;
  static const IconData check    = Icons.check_circle_rounded;
  static const IconData close    = Icons.close_rounded;
  static const IconData back     = Icons.arrow_back_rounded;
  static const IconData forward  = Icons.arrow_forward_rounded;
  static const IconData upload   = Icons.upload_rounded;
  static const IconData download = Icons.download_rounded;
  static const IconData share    = Icons.share_rounded;
  static const IconData filter   = Icons.filter_list_rounded;
  static const IconData sort     = Icons.sort_rounded;
  static const IconData stop     = Icons.stop_rounded;
  static const IconData build    = Icons.build_rounded;
  static const IconData gridView = Icons.grid_view_rounded;

  // Status
  static const IconData pending    = Icons.pending_outlined;
  static const IconData accepted   = Icons.check_circle_outline_rounded;
  static const IconData declined   = Icons.cancel_outlined;
  static const IconData completed  = Icons.done_all_rounded;
  static const IconData inProgress = Icons.hourglass_empty_rounded;

  // Bid model
  static const IconData bid            = Icons.local_offer_rounded;
  static const IconData bidOutlined    = Icons.local_offer_outlined;
  static const IconData tracking       = Icons.track_changes_rounded;
  static const IconData ratingFilled   = Icons.star_rounded;
  static const IconData ratingOutlined = Icons.star_outline_rounded;
  static const IconData timer          = Icons.timer_outlined;
  static const IconData timerActive    = Icons.timer_rounded;
  static const IconData wallet         = Icons.account_balance_wallet_outlined;

  // Settings
  static const IconData settings            = Icons.settings_rounded;
  static const IconData language            = Icons.language_rounded;
  static const IconData theme               = Icons.brightness_6_rounded;
  static const IconData notifications       = Icons.notifications_outlined;
  static const IconData notificationsActive = Icons.notifications_active_rounded;
  static const IconData help                = Icons.help_outline_rounded;
  static const IconData info                = Icons.info_outline_rounded;
  static const IconData logout              = Icons.logout_rounded;
  static const IconData deleteAccount       = Icons.no_accounts_outlined;

  // Map
  static const IconData location         = Icons.location_on_rounded;
  static const IconData locationOutlined = Icons.location_on_outlined;
  static const IconData myLocation       = Icons.my_location_rounded;
  static const IconData directions       = Icons.directions_rounded;
  static const IconData map              = Icons.map_outlined;
  static const IconData openWith         = Icons.open_with_rounded;
  static const IconData locationSearch   = Icons.location_searching_rounded;
  static const IconData locationOff      = Icons.location_off_rounded;

  // Feedback
  static const IconData error   = Icons.error_outline_rounded;
  static const IconData warning = Icons.warning_amber_rounded;
  static const IconData success = Icons.check_circle_outline_rounded;

  // Chat / media
  static const IconData send     = Icons.send_rounded;
  static const IconData attach   = Icons.attach_file_rounded;
  static const IconData image    = Icons.image_outlined;
  static const IconData camera   = Icons.camera_alt_outlined;
  static const IconData mic      = Icons.mic_rounded;
  static const IconData micOff   = Icons.mic_off_rounded;
  static const IconData gallery  = Icons.photo_library_rounded;
  static const IconData videocam = Icons.videocam_rounded;
  static const IconData play     = Icons.play_arrow_rounded;
  static const IconData pause    = Icons.pause_rounded;

  // Rating
  static const IconData star         = Icons.star_rounded;
  static const IconData starOutlined = Icons.star_outline_rounded;
  static const IconData starHalf     = Icons.star_half_rounded;

  // AI
  static const IconData ai         = Icons.auto_awesome_rounded;
  static const IconData aiOutlined = Icons.auto_awesome_outlined;

  // Form / step
  static const IconData editNote      = Icons.edit_note_rounded;
  static const IconData twilight      = Icons.wb_twilight_rounded;
  static const IconData calendarToday = Icons.calendar_today_rounded;
}

class AppRoutes {
  AppRoutes._();

  static const String splash            = '/';
  static const String login             = '/login';
  static const String register          = '/register';
  static const String forgotPassword    = '/forgot-password';
  static const String emailVerification = '/verify-email';
  static const String home              = '/home';
  static const String search            = '/search';
  static const String requests          = '/requests';
  static const String profile           = '/profile';
  static const String workerJobs        = '/worker-jobs';
  static const String workerSettings    = '/worker-settings';
  static const String serviceRequest    = '/service-request';
  static const String workerProfile     = '/worker/:id';
  static const String settings          = '/settings';
  static const String editProfile       = '/edit-profile';
  static const String notifications     = '/notifications';
  static const String help              = '/help';
  static const String about             = '/about';
  static const String bidsListScreen    = '/service-request/:id/bids';
  static const String requestTracking   = '/service-request/:id/tracking';
  static const String clientRating      = '/service-request/:id/rating';
  static const String submitBid         = '/worker/jobs/:id/bid';
  static const String workerJobDetail   = '/worker/jobs/:id';

  // KEPT — used only in app_router.dart redirect logic (not a registered route):
  static const String workerHome = '/worker-home';
}

class PrefKeys {
  PrefKeys._();

  static const String isFirstLaunch = 'is_first_launch';
  static const String languageCode  = 'language_code';
  static const String themeMode     = 'theme_mode';
  static const String userId        = 'user_id';
  static const String userType      = 'user_type';
  static const String viewMode      = 'view_mode';
  static const String accountRole   = 'account_role';
  static const String fcmToken      = 'fcm_token';
  static const String lastLocation  = 'last_location';
}

class UserType {
  UserType._();
  static const String user   = 'user';
  static const String worker = 'worker';
}

class ServiceType {
  ServiceType._();
  static const String plumbing        = 'plumber';
  static const String electrical      = 'electrician';
  static const String cleaning        = 'cleaner';
  static const String painting        = 'painter';
  static const String carpentry       = 'carpenter';
  static const String gardening       = 'gardener';
  static const String airConditioning = 'ac_repair';
  static const String appliances      = 'appliance_repair';
  static const String masonry         = 'mason';

  static List<String> get all => [
    plumbing, electrical, cleaning, painting,
    carpentry, gardening, airConditioning, appliances,
  ];
}
