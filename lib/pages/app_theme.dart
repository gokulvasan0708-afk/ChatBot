import 'package:flutter/material.dart';

// ================================================================
// NEXUS — SHARED APP THEME  (v2 · Purple "Connect • Collaborate • Grow")
// ----------------------------------------------------------------
// Single source of truth for the Nexus UI colour system:
//   1. Core brand colours   (Primary Purple, Dark, Light, Gold, Cyan)
//   2. Dark mode  (main theme)
//   3. Light mode
//   + Status / chat / call / category / gradient colours
//
// BACKWARD COMPATIBILITY
// The old warm-brown names (tan, saddleBrown, sienna, cream, glow,
// goldGradient, accentGradient, dark*/light*) are KEPT so every
// screen that has not been redesigned yet automatically picks up the
// new purple palette. They now simply point at the new colours.
// ================================================================

/// Global, app-wide dark/light mode switch.
///
///   ThemeController.instance.toggle();
///   ThemeController.instance.setMode(ThemeMode.light);
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController._() : super(ThemeMode.dark);

  static final ThemeController instance = ThemeController._();

  bool get isDark => value == ThemeMode.dark;

  void toggle() {
    value = isDark ? ThemeMode.light : ThemeMode.dark;
  }

  void setMode(ThemeMode mode) {
    value = mode;
  }
}

/// Static brand colours that never change with the theme mode.
class AppColors {
  AppColors._();

  // ================================================================
  // 1. CORE BRAND COLOURS
  // ================================================================
  static const Color primary = Color(0xFF7C3AED); // Primary Purple
  static const Color primaryDark = Color(0xFF5B21B6); // Primary Dark
  static const Color primaryLight = Color(0xFFA78BFA); // Light Purple
  static const Color goldAccent = Color(0xFFF5B942); // Gold Accent
  static const Color cyanAccent = Color(0xFF22D3EE); // Cyan Accent
  static const Color deepSpace = Color(0xFF0F0F14); // Deep Space
  static const Color iconLavender = Color(0xFFC4B5FD); // Icon on dark
  static const Color iconLight = Color(0xFF6D2BD9); // Icon on light

  // ================================================================
  // STATUS COLOURS
  // ================================================================
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color online = Color(0xFF10B981);
  static const Color pink = Color(0xFFEC4899);

  // ================================================================
  // CHAT / CALL COLOURS
  // ================================================================
  static const Color chatOthersBubble = Color(0xFF20202A);
  static const Color chatMyBubble = Color(0xFF7C3AED);
  static const Color chatBackground = Color(0xFF0F0F14);
  static const Color chatTimestamp = Color(0xFF898997);
  static const Color callVoice = Color(0xFF22D3EE);
  static const Color callVideo = Color(0xFF7C3AED);
  static const Color callEnd = Color(0xFFEF4444);

  // ================================================================
  // GRADIENTS
  // ================================================================

  /// Brand mark gradient (logo): purple -> cyan.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, cyanAccent],
  );

  /// AI assistant gradients.
  static const LinearGradient aiGradient1 = LinearGradient(
    colors: [primary, cyanAccent],
  );
  static const LinearGradient aiGradient2 = LinearGradient(
    colors: [primary, pink],
  );
  static const LinearGradient aiGradient3 = LinearGradient(
    colors: [primaryDark, goldAccent],
  );

  /// Primary button gradient.
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [primary, Color(0xFF6D28D9)],
  );

  // ---- Legacy names (kept so un-redesigned screens turn purple) ----
  static const Color tan = primaryLight; // A78BFA
  static const Color saddleBrown = primary; // 7C3AED
  static const Color sienna = primaryDark; // 5B21B6
  static const Color cream = Color(0xFFEDE9FE);
  static const Color glow = iconLavender; // C4B5FD

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [primaryDark, primary, primaryLight],
  );

  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, primaryDark],
  );

  // ================================================================
  // 2. DARK MODE (main theme)
  // ================================================================
  static const Color darkBgTop = Color(0xFF19132B); // soft purple haze
  static const Color darkBgMid = Color(0xFF0F0F14); // Background
  static const Color darkBgBottom = Color(0xFF0A0A0E);
  static const Color darkCard = Color(0xFF18181F); // Cards
  static const Color darkElevated = Color(0xFF20202A); // Elevated cards
  static const Color darkBottomNav = Color(0xFF13131A); // Bottom navigation
  static const Color darkSecondaryButton = Color(0xFF2A2438);
  static const Color darkCardBorder = Color(0xFF292934); // Divider / border
  static const Color darkInputBorder = Color(0xFF343440);
  static const Color darkSheet = Color(0xFF18181F);
  static const Color darkAvatarBg = Color(0xFF2A2438);
  static const Color darkTextPrimary = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFFB8B6C7);
  static const Color darkTextMuted = Color(0xFF777784); // Placeholder

  // ================================================================
  // 3. LIGHT MODE
  // ================================================================
  static const Color lightBgTop = Color(0xFFFFFFFF);
  static const Color lightBgMid = Color(0xFFF6F7FC); // Background
  static const Color lightBgBottom = Color(0xFFEEEBFB);
  static const Color lightCard = Color(0xFFFFFFFF); // Cards
  static const Color lightElevated = Color(0xFFF3F0FF); // Elevated cards
  static const Color lightCardBorder = Color(0xFFDDD7E8); // Border
  static const Color lightDivider = Color(0xFFE7E3EE);
  static const Color lightSheet = Color(0xFFFFFFFF);
  static const Color lightAvatarBg = Color(0xFFE9E3FB);
  static const Color lightTextPrimary = Color(0xFF17141F);
  static const Color lightTextSecondary = Color(0xFF6B6575);
  static const Color lightTextMuted = Color(0xFF8E8899);

  /// Surface/text colours for the current brightness.
  static AppColorSet of(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? dark : light;
  }

  static const AppColorSet dark = AppColorSet(
    bgTop: darkBgTop,
    bgMid: darkBgMid,
    bgBottom: darkBgBottom,
    card: darkCard,
    cardBorder: darkCardBorder,
    sheet: darkSheet,
    avatarBg: darkAvatarBg,
    textPrimary: darkTextPrimary,
    textSecondary: darkTextSecondary,
    textMuted: darkTextMuted,
    starColor: Colors.white,
    elevated: darkElevated,
    navBg: darkBottomNav,
    inputBorder: darkInputBorder,
    secondaryButton: darkSecondaryButton,
    icon: iconLavender,
    accent: primaryLight,
  );

  static const AppColorSet light = AppColorSet(
    bgTop: lightBgTop,
    bgMid: lightBgMid,
    bgBottom: lightBgBottom,
    card: lightCard,
    cardBorder: lightCardBorder,
    sheet: lightSheet,
    avatarBg: lightAvatarBg,
    textPrimary: lightTextPrimary,
    textSecondary: lightTextSecondary,
    textMuted: lightTextMuted,
    starColor: primary,
    elevated: lightElevated,
    navBg: lightCard,
    inputBorder: lightCardBorder,
    secondaryButton: lightElevated,
    icon: iconLight,
    accent: primary,
  );
}

/// A bundle of surface/text colours for one brightness mode.
class AppColorSet {
  final Color bgTop;
  final Color bgMid;
  final Color bgBottom;
  final Color card;
  final Color cardBorder;
  final Color sheet;
  final Color avatarBg;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color starColor;

  // New in the purple redesign.
  final Color elevated;
  final Color navBg;
  final Color inputBorder;
  final Color secondaryButton;
  final Color icon;
  final Color accent;

  const AppColorSet({
    required this.bgTop,
    required this.bgMid,
    required this.bgBottom,
    required this.card,
    required this.cardBorder,
    required this.sheet,
    required this.avatarBg,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.starColor,
    required this.elevated,
    required this.navBg,
    required this.inputBorder,
    required this.secondaryButton,
    required this.icon,
    required this.accent,
  });
}

/// The two [ThemeData] objects the app switches between.
class AppTheme {
  AppTheme._();

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.darkBgMid,
        canvasColor: AppColors.darkBgMid,
        cardColor: AppColors.darkCard,
        dividerColor: AppColors.darkCardBorder,
        fontFamily: 'Roboto',
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          onPrimary: Colors.white,
          secondary: AppColors.primaryLight,
          tertiary: AppColors.cyanAccent,
          surface: AppColors.darkCard,
          onSurface: AppColors.darkTextPrimary,
          error: AppColors.error,
          outline: AppColors.darkCardBorder,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.white,
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.darkCardBorder,
          thickness: 1,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppColors.darkSheet,
          surfaceTintColor: Colors.transparent,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.darkSheet,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? Colors.white
                : AppColors.darkTextMuted,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? AppColors.primary
                : AppColors.darkElevated,
          ),
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: AppColors.primaryLight,
          selectionColor: Color(0x557C3AED),
          selectionHandleColor: AppColors.primary,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppColors.primary,
        ),
      );

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.lightBgMid,
        canvasColor: AppColors.lightBgMid,
        cardColor: AppColors.lightCard,
        dividerColor: AppColors.lightDivider,
        fontFamily: 'Roboto',
        colorScheme: const ColorScheme.light(
          primary: AppColors.primary,
          onPrimary: Colors.white,
          secondary: AppColors.primaryDark,
          tertiary: AppColors.cyanAccent,
          surface: AppColors.lightCard,
          onSurface: AppColors.lightTextPrimary,
          error: AppColors.error,
          outline: AppColors.lightCardBorder,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: AppColors.lightTextPrimary,
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.lightDivider,
          thickness: 1,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppColors.lightSheet,
          surfaceTintColor: Colors.transparent,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.lightSheet,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? Colors.white
                : AppColors.lightTextMuted,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? AppColors.primary
                : AppColors.lightCardBorder,
          ),
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: AppColors.primary,
          selectionColor: Color(0x447C3AED),
          selectionHandleColor: AppColors.primary,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppColors.primary,
        ),
      );
}
