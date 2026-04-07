// lib/utils/app_theme.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/message_enums.dart';
import 'constants.dart';

/// ============================================================
/// 🎨 KHIDMETI APP THEME — Midnight Indigo v2.0
/// ============================================================

class AppTheme {
  // ==========================================================
  // 🎨 CORE PALETTE — DARK THEME
  // ==========================================================

  static const Color darkBackground     = Color(0xFF080510);
  static const Color darkSurface        = Color(0xFF141028);
  static const Color darkSurfaceVariant = Color(0xFF1C1235);
  static const Color darkDeepBackground = Color(0xFF120820);
  static const Color darkText           = Color(0xFFF0EAFF);
  static const Color darkSecondaryText  = Color(0xFF7A6E96);
  static const Color darkTertiaryText   = Color(0xFF4A4260);
  static const Color darkAccent         = Color(0xFF4F46E5);
  static const Color darkBorder         = Color(0xFF221640);
  static const Color darkError          = Color(0xFFF87171);
  static const Color darkSuccess        = Color(0xFF34D399);
  static const Color darkWarning        = Color(0xFFFBBF24);

  // ==========================================================
  // 🎨 CORE PALETTE — LIGHT THEME
  // ==========================================================

  static const Color lightBackground    = Color(0xFFF8F7FF);
  static const Color lightSurface       = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant= Color(0xFFF0EEFF);
  static const Color lightText          = Color(0xFF12041C);
  static const Color lightSecondaryText = Color(0xFF6B64A0);
  static const Color lightTertiaryText  = Color(0xFFA8A2D4);
  static const Color lightAccent        = Color(0xFF4F46E5);
  static const Color lightBorder        = Color(0xFFE0DBFF);
  static const Color lightError         = Color(0xFFDC2626);
  static const Color lightSuccess       = Color(0xFF16A34A);
  static const Color lightWarning       = Color(0xFFD97706);

  // ==========================================================
  // 🎨 OPACITY-BAKED TOKENS
  //
  // Design contract:
  //   • No inline .withOpacity() calls anywhere in this file.
  //   • All semi-transparent values are pre-baked const Colors.
  //   • Alpha channel is encoded directly in the hex value so the
  //     token remains a compile-time constant.
  //   • Naming convention: <base>_<usage> or <base><Opacity%>.
  //     e.g. darkBgAppBar = darkBackground @ 80 % opacity.
  //
  // Alpha reference (opacity → hex):
  //   4%  → 0x0A  |  6%  → 0x0F  |  7%  → 0x12  |  8%  → 0x14
  //   10% → 0x1A  |  12% → 0x1F  |  15% → 0x26  |  18% → 0x2E
  //   20% → 0x33  |  25% → 0x40  |  30% → 0x4D  |  35% → 0x59
  //   45% → 0x73  |  50% → 0x80  |  60% → 0x99  |  70% → 0xB3
  //   80% → 0xCC  |  90% → 0xE6
  // ==========================================================

  // ── Dark — app bar background (darkBackground @ 80%) ─────────────────────
  static const Color darkBgAppBar = Color(0xCC080510);

  // ── Dark — input error border (darkError @ 80%) ──────────────────────────
  static const Color darkErrorBorder = Color(0xCCF87171);

  // ── Dark — input hint text (darkSecondaryText @ 60%) ─────────────────────
  static const Color darkHintText = Color(0x997A6E96);

  // ── Dark — subtle border used in outlined buttons / snackbars / dialogs /
  //    dividers / chip borders (darkBorder @ 20%) ──────────────────────────
  static const Color darkBorderSubtle = Color(0x33221640);

  // ── Dark — chip selected fill + slider overlay (darkAccent @ 20%) ────────
  static const Color darkAccentOverlay = Color(0x334F46E5);

  // ── Dark — switch track (selected) (darkAccent @ 50%) ────────────────────
  static const Color darkAccentMid = Color(0x804F46E5);

  // ── Dark — switch track (unselected) (darkSurfaceVariant @ 50%) ──────────
  static const Color darkSurfaceVariantMid = Color(0x801C1235);

  // ── Dark — error icon background in SplashErrorIcon (darkError @ 10%) ────
  static const Color darkErrorSubtle = Color(0x1AF87171);

  // ── Dark — muted error icon color (darkError @ 60%) ──────────────────────
  static const Color darkErrorMuted = Color(0x99F87171);

  // ── Dark — social button surface (darkSurface @ 50%) ─────────────────────
  // FIX [Col-OPAC]: darkSurface.withOpacity(0.5) → pre-baked const token.
  // darkSurface #141028 @ 50% → alpha 0x80
  static const Color darkSurfaceHalf = Color(0x80141028);

  // ── Light — app bar background (lightBackground @ 90%) ───────────────────
  static const Color lightBgAppBar = Color(0xE6F8F7FF);

  // ── Light — input error border (lightError @ 80%) ────────────────────────
  static const Color lightErrorBorder = Color(0xCCDC2626);

  // ── Light — input hint text (lightSecondaryText @ 70%) ───────────────────
  static const Color lightHintText = Color(0xB36B64A0);

  // ── Light — chip selected fill (lightAccent @ 15%) ───────────────────────
  static const Color lightAccentChipOverlay = Color(0x264F46E5);

  // ── Light — slider overlay (lightAccent @ 20%) ───────────────────────────
  static const Color lightAccentOverlay = Color(0x334F46E5);

  // ── Light — switch track (selected) (lightAccent @ 50%) ──────────────────
  static const Color lightAccentMid = Color(0x804F46E5);

  // ── Light — error icon background in SplashErrorIcon (lightError @ 10%) ──
  static const Color lightErrorSubtle = Color(0x1ADC2626);

  // ── Light — muted error icon color (lightError @ 60%) ────────────────────
  static const Color lightErrorMuted = Color(0x99DC2626);

  // ==========================================================
  // 🎨 AUTH / SHEET OPACITY-BAKED TOKENS
  // ==========================================================

  // ── Auth background radial halo ───────────────────────────────────────────
  // darkAccent #4F46E5 @ 18% → alpha 0x2E
  static const Color darkAccentHalo  = Color(0x2E4F46E5);
  // lightAccent #4F46E5 @ 7%  → alpha 0x12
  static const Color lightAccentHalo = Color(0x124F46E5);

  // ── Accent box-shadow colour (darkAccent @ 35%) ───────────────────────────
  // Used for logo orb, auth submit button, and any elevated accent surface.
  // NOTE: same hex value as profileCardShadow (Color(0x594F46E5)). Kept as
  // a separate named token to allow future divergence between profile card
  // shadows and auth element shadows without a breaking rename.
  // darkAccent #4F46E5 @ 35% → alpha 0x59
  static const Color accentShadow = Color(0x594F46E5);

  // ── Accent disabled background (darkAccent @ 45%) ─────────────────────────
  // Used for the auth submit button in its disabled state.
  // darkAccent #4F46E5 @ 45% → alpha 0x73
  static const Color accentDisabledFill = Color(0x734F46E5);

  // ── Accent selected tile fill (accent @ 15%) ─────────────────────────────
  // Used in ProfessionPickerSheet selected tile background.
  // Both themes share the same accent colour today (#4F46E5).
  // accent #4F46E5 @ 15% → alpha 0x26
  static const Color accentSelectedFill = Color(0x264F46E5);

  // ── Sheet drag handle ─────────────────────────────────────────────────────
  // white @ 15% → alpha 0x26
  static const Color sheetHandleDark  = Color(0x26FFFFFF);
  // black @ 12% → alpha 0x1F
  static const Color sheetHandleLight = Color(0x1F000000);

  // ── Warning subtle fill — lockout / rate-limit banner ────────────────────
  // darkWarning #FBBF24 @ 8% → alpha 0x14
  static const Color darkWarningSubtle  = Color(0x14FBBF24);
  // lightWarning #D97706 @ 8% → alpha 0x14
  static const Color lightWarningSubtle = Color(0x14D97706);

  // ── Warning border — lockout / rate-limit banner ──────────────────────────
  // darkWarning #FBBF24 @ 30% → alpha 0x4D
  static const Color darkWarningBorder  = Color(0x4DFBBF24);
  // lightWarning #D97706 @ 30% → alpha 0x4D
  static const Color lightWarningBorder = Color(0x4DD97706);

  // ── Surface tile unselected fill ──────────────────────────────────────────
  // white @ 6% → alpha 0x0F
  static const Color darkTileFill  = Color(0x0FFFFFFF);
  // black @ 4% → alpha 0x0A
  static const Color lightTileFill = Color(0x0A000000);

  // ── Surface tile unselected border ────────────────────────────────────────
  // white @ 10% → alpha 0x1A
  static const Color darkTileBorder  = Color(0x1AFFFFFF);
  // black @ 8% → alpha 0x14
  static const Color lightTileBorder = Color(0x14000000);

  // ── Social button border (dark theme) ────────────────────────────────────
  // white @ 18% → alpha 0x2E
  static const Color darkSocialBorder = Color(0x2EFFFFFF);

  // ── Back button circular container fill ───────────────────────────────────
  // white @ 8% → alpha 0x14
  static const Color darkBackButtonFill  = Color(0x14FFFFFF);
  // black @ 6% → alpha 0x0F
  static const Color lightBackButtonFill = Color(0x0F000000);

  // ── Checkbox unchecked border ─────────────────────────────────────────────
  // white @ 25% → alpha 0x40
  static const Color darkCheckboxBorder  = Color(0x40FFFFFF);
  // black @ 20% → alpha 0x33
  static const Color lightCheckboxBorder = Color(0x33000000);

  // ==========================================================
  // 🎨 OVERLAY TOKENS
  // ==========================================================

  static const Color overlayScrim35 = Color(0x59000000);

  // ==========================================================
  // 🎨 PROFILE CARD TOKENS
  // ==========================================================

  static const Color profileCardBorder      = Color(0x33FFFFFF);
  static const Color profileCardBadgeFill   = Color(0x33FFFFFF);
  static const Color profileCardShadow      = Color(0x594F46E5);
  static const Color profileCardAvatarBorder= Color(0x80FFFFFF);
  static const Color profileCardRatingText  = Color(0xE6FFFFFF);

  // ==========================================================
  // 🎨 SETTINGS ICON COLOUR TOKENS
  // ==========================================================

  static const Color iconIndigo  = Color(0xFF6366F1);
  static const Color iconViolet  = Color(0xFF8B5CF6);
  static const Color iconEmerald = Color(0xFF10B981);
  static const Color iconPink    = Color(0xFFEC4899);

  // ==========================================================
  // 🎨 TOKENS — misc
  // ==========================================================

  static const Color whatsAppDarkSurface    = Color(0xFF1B2B1B);
  static const Color lightCardBorderOverlay = Color(0x12000000);
  static const Color darkCardBorderOverlay  = Color(0x12FFFFFF);

  static const List<Shadow> profileCardTextShadow = [
    Shadow(color: Color(0xAA000000), blurRadius: 8, offset: Offset(0, 2)),
  ];

  static const Color promoBlueDark  = Color(0xFF60A5FA);
  static const Color promoBlueLight = Color(0xFF2563EB);

  static const Color darkSecondaryTextWcag = Color(0xFF9B91C0);

  static const Color overlayDark = Color(0x73000000);

  // ==========================================================
  // 🎨 MODAL SHADOW TOKENS
  // ==========================================================

  static const BoxShadow modalShadowDark = BoxShadow(
    color:      Color(0x66000000),
    blurRadius: 24,
    offset:     Offset(0, -4),
  );

  static const BoxShadow modalShadowLight = BoxShadow(
    color:      Color(0x2E000000),
    blurRadius: 24,
    offset:     Offset(0, -4),
  );

  // ==========================================================
  // 🎨 SHIMMER / SKELETON TOKENS
  // ==========================================================

  static const Color shimmerBaseDark        = Color(0x12F0EAFF);
  static const Color shimmerHighlightDark   = Color(0x26F0EAFF);
  static const Color shimmerBaseLight       = Color(0x0D12041C);
  static const Color shimmerHighlightLight  = Color(0x1A12041C);

  // ==========================================================
  // 🎨 WHATSAPP TOKENS
  // ==========================================================

  static const Color whatsAppGreen = Color(0xFF25D366);
  static const Color whatsAppDark  = Color(0xFF128C7E);

  // ==========================================================
  // 🎨 FEATURE / KEPT COLOURS
  // ==========================================================

  static const Color aiPrimary          = Color(0xFF6C47FF);
  static const Color onlineGreen        = Color(0xFF22C55E);
  static const Color recordingRed       = Color(0xFFF44336);
  static const Color signOutRed         = Color(0xFFEF4444);
  static const Color priorityNormalDark = Color(0xFF34D399);
  static const Color warningAmber       = Color(0xFFFBBF24);
  static const Color cyanBlue           = Color(0xFF06B6D4);
  static const Color acceptGreen        = Color(0xFF16A34A);
  static const Color darkAuthHeroTop    = Color(0xFF120820);

  // ==========================================================
  // 🎨 STATUS COLOUR TOKENS
  // ==========================================================

  static const Color statusOpenDark  = Color(0xCC4F46E5);
  static const Color statusOpenLight = Color(0xCC4F46E5);

  static const Color statusAcceptedDark  = Color(0xFF60A5FA);
  static const Color statusAcceptedLight = Color(0xFF2563EB);

  static const Color statusInProgressDark  = Color(0xFFA78BFA);
  static const Color statusInProgressLight = Color(0xFF7C3AED);

  static const Color statusCancelledDark  = Color(0xFFF87171);
  static const Color statusCancelledLight = Color(0xFFDC2626);

  // ==========================================================
  // 🎨 DISABLED STATE
  // ==========================================================

  static const Color disabledFill   = Color(0x1A9E9E9E);
  static const Color disabledBorder = Color(0x339E9E9E);

  // ==========================================================
  // 🌑 DARK THEME
  // ==========================================================

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness:   Brightness.dark,
      colorScheme: const ColorScheme.dark(
        brightness:              Brightness.dark,
        primary:                 darkAccent,
        onPrimary:               Colors.white,
        secondary:               darkAccent,
        onSecondary:             Colors.white,
        surface:                 darkSurface,
        onSurface:               darkText,
        surfaceContainerLowest:  darkBackground,
        error:                   darkError,
        onError:                 Colors.black,
        surfaceContainerHighest: darkSurfaceVariant,
        outline:                 darkBorder,
      ),
      scaffoldBackgroundColor: darkBackground,
      cardTheme: CardTheme(
        elevation:   0,
        color:       darkSurface,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusCard),
          side: const BorderSide(color: darkBorder, width: 0.5),
        ),
        margin: const EdgeInsets.all(8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled:    true,
        fillColor: darkSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: darkBorder, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: darkBorder, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: darkAccent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: darkErrorBorder, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: darkError, width: 1.5),
        ),
        labelStyle:         const TextStyle(color: darkSecondaryText, fontFamily: 'Inter', fontWeight: FontWeight.w400),
        floatingLabelStyle: const TextStyle(color: darkAccent, fontWeight: FontWeight.w600, fontFamily: 'Inter'),
        hintStyle:          const TextStyle(color: darkHintText, fontFamily: 'Inter'),
        contentPadding:     const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        prefixIconColor:    darkSecondaryText,
        suffixIconColor:    darkSecondaryText,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: darkAccent,
          foregroundColor: Colors.white,
          elevation:       0,
          minimumSize:     const Size(double.infinity, AppConstants.buttonHeight),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusLg)),
          textStyle: const TextStyle(fontSize: AppConstants.buttonFontSize, fontWeight: FontWeight.w700, letterSpacing: -0.2, fontFamily: 'Inter'),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: darkAccent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'Inter'),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: darkText,
          side: const BorderSide(color: darkBorderSubtle, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusLg)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'Inter'),
        ),
      ),
      appBarTheme: const AppBarTheme(
        elevation:              0,
        scrolledUnderElevation: 0,
        backgroundColor:        darkBgAppBar,
        foregroundColor:        darkText,
        centerTitle:            true,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor:          Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: TextStyle(color: darkText, fontSize: 17, fontWeight: FontWeight.w600, fontFamily: 'Inter', letterSpacing: -0.3),
        iconTheme:        IconThemeData(color: darkAccent, size: 24),
        actionsIconTheme: IconThemeData(color: darkText),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor:      darkSurface,
        selectedItemColor:    darkAccent,
        unselectedItemColor:  darkSecondaryText,
        type:                 BottomNavigationBarType.fixed,
        elevation:            0,
        selectedLabelStyle:   const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, fontFamily: 'Inter'),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400, fontSize: 12, fontFamily: 'Inter'),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: darkSurface,
        contentTextStyle: const TextStyle(color: darkText, fontFamily: 'Inter', fontWeight: FontWeight.w400),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          side: const BorderSide(color: darkBorderSubtle),
        ),
        behavior:     SnackBarBehavior.floating,
        elevation:    0,
        insetPadding: const EdgeInsets.all(16),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusXxl),
          side: const BorderSide(color: darkBorderSubtle, width: 0.5),
        ),
        titleTextStyle:   const TextStyle(color: darkText, fontSize: 20, fontWeight: FontWeight.w700, fontFamily: 'Inter'),
        contentTextStyle: const TextStyle(color: darkSecondaryText, fontSize: 15, fontFamily: 'Inter'),
      ),
      textTheme: const TextTheme(
        displayLarge:  TextStyle(fontSize: 40, fontWeight: FontWeight.w700, color: darkText, fontFamily: 'Inter', letterSpacing: -1.5),
        displayMedium: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: darkText, fontFamily: 'Inter', letterSpacing: -1),
        displaySmall:  TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: darkText, fontFamily: 'Inter', letterSpacing: -0.5),
        headlineLarge: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: darkText, fontFamily: 'Inter', letterSpacing: -0.5),
        headlineMedium:TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: darkText, fontFamily: 'Inter', letterSpacing: -0.6),
        headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: darkText, fontFamily: 'Inter', letterSpacing: -0.3),
        titleLarge:    TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: darkText, fontFamily: 'Inter'),
        titleMedium:   TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: darkText, fontFamily: 'Inter'),
        titleSmall:    TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: darkSecondaryTextWcag, fontFamily: 'Inter'),
        bodyLarge:     TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: darkText, fontFamily: 'Inter', height: 1.6),
        bodyMedium:    TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: darkText, fontFamily: 'Inter', height: 1.6),
        bodySmall:     TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: darkSecondaryTextWcag, fontFamily: 'Inter', height: 1.5),
        labelLarge:    TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: darkText, fontFamily: 'Inter'),
        labelMedium:   TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: darkSecondaryTextWcag, fontFamily: 'Inter'),
        labelSmall:    TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: darkText, fontFamily: 'Inter', letterSpacing: 0.10),
      ),
      dividerTheme: const DividerThemeData(color: darkBorderSubtle, thickness: 1, space: 24),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppConstants.radiusXxl))),
        elevation: 0,
      ),
      chipTheme: ChipThemeData(
        backgroundColor:     darkSurfaceVariant,
        selectedColor:       darkAccentOverlay,
        labelStyle:          const TextStyle(color: darkText, fontFamily: 'Inter', fontWeight: FontWeight.w400),
        secondaryLabelStyle: const TextStyle(color: darkAccent, fontFamily: 'Inter', fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.chipPaddingH, vertical: AppConstants.chipPaddingV),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.chipRadius),
          side: const BorderSide(color: darkBorderSubtle),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (s) => s.contains(WidgetState.selected) ? darkAccent : darkSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (s) => s.contains(WidgetState.selected)
              ? darkAccentMid
              : darkSurfaceVariantMid,
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor:   darkAccent,
        inactiveTrackColor: darkSurfaceVariant,
        thumbColor:         darkAccent,
        overlayColor:       darkAccentOverlay,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color:              darkAccent,
        circularTrackColor: darkSurfaceVariant,
        linearTrackColor:   darkSurfaceVariant,
      ),
    );
  }

  // ==========================================================
  // ☀️ LIGHT THEME
  // ==========================================================

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness:   Brightness.light,
      colorScheme: const ColorScheme.light(
        brightness:              Brightness.light,
        primary:                 lightAccent,
        onPrimary:               Colors.white,
        secondary:               lightAccent,
        onSecondary:             Colors.white,
        surface:                 lightSurface,
        onSurface:               lightText,
        surfaceContainerLowest:  lightBackground,
        error:                   lightError,
        onError:                 Colors.white,
        surfaceContainerHighest: lightSurfaceVariant,
        outline:                 lightBorder,
      ),
      scaffoldBackgroundColor: lightBackground,
      cardTheme: CardTheme(
        elevation:   0,
        color:       lightSurface,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusCard),
          side: const BorderSide(color: lightBorder, width: 0.5),
        ),
        margin: const EdgeInsets.all(8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled:    true,
        fillColor: lightSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: lightBorder, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: lightBorder, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: lightAccent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: lightErrorBorder, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.inputRadius),
          borderSide: const BorderSide(color: lightError, width: 1.5),
        ),
        labelStyle:         const TextStyle(color: lightSecondaryText, fontFamily: 'Inter', fontWeight: FontWeight.w400),
        floatingLabelStyle: const TextStyle(color: lightAccent, fontWeight: FontWeight.w600, fontFamily: 'Inter'),
        hintStyle:          const TextStyle(color: lightHintText, fontFamily: 'Inter'),
        contentPadding:     const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        prefixIconColor:    lightSecondaryText,
        suffixIconColor:    lightSecondaryText,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: lightAccent,
          foregroundColor: Colors.white,
          elevation:       0,
          minimumSize:     const Size(double.infinity, AppConstants.buttonHeight),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusLg)),
          textStyle: const TextStyle(fontSize: AppConstants.buttonFontSize, fontWeight: FontWeight.w700, letterSpacing: -0.2, fontFamily: 'Inter'),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: lightAccent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'Inter'),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: lightText,
          side: const BorderSide(color: lightBorder, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusLg)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'Inter'),
        ),
      ),
      appBarTheme: const AppBarTheme(
        elevation:              0,
        scrolledUnderElevation: 0,
        backgroundColor:        lightBgAppBar,
        foregroundColor:        lightText,
        centerTitle:            true,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor:          Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
        ),
        titleTextStyle:   TextStyle(color: lightText, fontSize: 17, fontWeight: FontWeight.w600, fontFamily: 'Inter', letterSpacing: -0.3),
        iconTheme:        IconThemeData(color: lightAccent, size: 24),
        actionsIconTheme: IconThemeData(color: lightText),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor:      lightSurface,
        selectedItemColor:    lightAccent,
        unselectedItemColor:  lightSecondaryText,
        type:                 BottomNavigationBarType.fixed,
        elevation:            0,
        selectedLabelStyle:   const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, fontFamily: 'Inter'),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400, fontSize: 12, fontFamily: 'Inter'),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: lightText,
        contentTextStyle: const TextStyle(color: Colors.white, fontFamily: 'Inter', fontWeight: FontWeight.w400),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLg),
          side: const BorderSide(color: lightBorder),
        ),
        behavior:     SnackBarBehavior.floating,
        elevation:    4,
        insetPadding: const EdgeInsets.all(16),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusXxl),
          side: const BorderSide(color: lightBorder, width: 0.5),
        ),
        titleTextStyle:   const TextStyle(color: lightText, fontSize: 20, fontWeight: FontWeight.w700, fontFamily: 'Inter'),
        contentTextStyle: const TextStyle(color: lightSecondaryText, fontSize: 15, fontFamily: 'Inter'),
      ),
      textTheme: const TextTheme(
        displayLarge:  TextStyle(fontSize: 40, fontWeight: FontWeight.w700, color: lightText, fontFamily: 'Inter', letterSpacing: -1.5),
        displayMedium: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: lightText, fontFamily: 'Inter', letterSpacing: -1),
        displaySmall:  TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: lightText, fontFamily: 'Inter', letterSpacing: -0.5),
        headlineLarge: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: lightText, fontFamily: 'Inter', letterSpacing: -0.5),
        headlineMedium:TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: lightText, fontFamily: 'Inter', letterSpacing: -0.6),
        headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: lightText, fontFamily: 'Inter', letterSpacing: -0.3),
        titleLarge:    TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: lightText, fontFamily: 'Inter'),
        titleMedium:   TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: lightText, fontFamily: 'Inter'),
        titleSmall:    TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: lightSecondaryText, fontFamily: 'Inter'),
        bodyLarge:     TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: lightText, fontFamily: 'Inter', height: 1.6),
        bodyMedium:    TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: lightText, fontFamily: 'Inter', height: 1.6),
        bodySmall:     TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: lightSecondaryText, fontFamily: 'Inter', height: 1.5),
        labelLarge:    TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: lightText, fontFamily: 'Inter'),
        labelMedium:   TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: lightSecondaryText, fontFamily: 'Inter'),
        labelSmall:    TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: lightText, fontFamily: 'Inter', letterSpacing: 0.10),
      ),
      dividerTheme:     const DividerThemeData(color: lightBorder, thickness: 1, space: 24),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppConstants.radiusXxl))),
        elevation: 0,
      ),
      chipTheme: ChipThemeData(
        backgroundColor:     lightSurfaceVariant,
        selectedColor:       lightAccentChipOverlay,
        labelStyle:          const TextStyle(color: lightText, fontFamily: 'Inter', fontWeight: FontWeight.w400),
        secondaryLabelStyle: const TextStyle(color: lightAccent, fontFamily: 'Inter', fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.chipPaddingH, vertical: AppConstants.chipPaddingV),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.chipRadius),
          side: const BorderSide(color: lightBorder, width: 0.5),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (s) => s.contains(WidgetState.selected) ? lightAccent : lightSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (s) => s.contains(WidgetState.selected) ? lightAccentMid : lightBorder,
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor:   lightAccent,
        inactiveTrackColor: lightBorder,
        thumbColor:         lightAccent,
        overlayColor:       lightAccentOverlay,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color:              lightAccent,
        circularTrackColor: lightSurfaceVariant,
        linearTrackColor:   lightSurfaceVariant,
      ),
    );
  }

  // ==========================================================
  // 🎨 HELPER METHODS
  // ==========================================================

  static Color getStatusColor(ServiceStatus status, bool isDark) {
    switch (status) {
      case ServiceStatus.open:
      case ServiceStatus.pending:
        return isDark ? statusOpenDark : statusOpenLight;
      case ServiceStatus.awaitingSelection:
        return isDark ? darkWarning : lightWarning;
      case ServiceStatus.bidSelected:
      case ServiceStatus.accepted:
        return isDark ? statusAcceptedDark : statusAcceptedLight;
      case ServiceStatus.inProgress:
        return isDark ? statusInProgressDark : statusInProgressLight;
      case ServiceStatus.completed:
        return isDark ? darkSuccess : lightSuccess;
      case ServiceStatus.cancelled:
      case ServiceStatus.declined:
      case ServiceStatus.expired:
        return isDark ? statusCancelledDark : statusCancelledLight;
    }
  }

  static IconData getProfessionIcon(String serviceType) {
    const map = <String, IconData>{
      'plumber':          Icons.plumbing_rounded,
      'electrician':      Icons.electrical_services_rounded,
      'cleaner':          Icons.cleaning_services_rounded,
      'painter':          Icons.format_paint_rounded,
      'carpenter':        Icons.carpenter_rounded,
      'mason':            Icons.domain_rounded,
      'ac_repair':        Icons.air_rounded,
      'gardener':         Icons.grass_rounded,
      'appliance_repair': Icons.kitchen_rounded,
    };
    return map[serviceType] ?? Icons.work_outline_rounded;
  }
}
