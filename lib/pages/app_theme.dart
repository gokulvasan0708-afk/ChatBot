import 'package:flutter/material.dart';

// ================================================================
// NEXUS — SHARED APP THEME
// ----------------------------------------------------------------
// Single source of truth for the "warm cosmic" color palette used
// across every screen (Splash, Get Started, Login, Chat List,
// Chat Screen, Me Page, Notifications).
//
// Palette taken from the Nexus brand reference:
//   Tan          #D2B48C
//   Saddle Brown #8B4513
//   Sienna       #A0522D
//   Cream        #FFFDD0
// ================================================================

/// Global, app-wide dark/light mode switch.
///
/// Any widget can flip the mode with:
///   ThemeController.instance.toggle();
/// or
///   ThemeController.instance.setMode(ThemeMode.light);
///
/// `main.dart` listens to this notifier and rebuilds the
/// [MaterialApp] with the matching [ThemeData], so switching modes
/// from the Me Page → Settings → Mode button applies instantly
/// throughout the entire app.
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

/// Static brand colors that never change with the theme mode
/// (buttons, glows, badges, gradients — the "gold" identity of
/// the app stays the same in both Dark and Light mode).
class AppColors {
  AppColors._();

  // ---- Brand / accent -------------------------------------------------
  static const Color tan = Color(0xFFD2B48C);
  static const Color saddleBrown = Color(0xFF8B4513);
  static const Color sienna = Color(0xFFA0522D);
  static const Color cream = Color(0xFFFFFDD0);
  static const Color glow = Color(0xFFFFE9B0);

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [sienna, saddleBrown, tan],
  );

  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [tan, Color(0xFFC9A063), saddleBrown],
  );

  // ---- Dark mode surfaces ----------------------------------------------
  static const Color darkBgTop = Color(0xFF1D1208);
  static const Color darkBgMid = Color(0xFF0A0704);
  static const Color darkBgBottom = Color(0xFF000000);
  static const Color darkCard = Color(0xFF120C07);
  static const Color darkCardBorder = Color(0x998B6A3F);
  static const Color darkSheet = Color(0xFF1B120A);
  static const Color darkAvatarBg = Color(0xFF2A1B0E);
  static const Color darkTextPrimary = Colors.white;
  static const Color darkTextSecondary = Color(0xFFE3D2B0);
  static const Color darkTextMuted = Color(0xFFAB8A63);

  // ---- Light mode surfaces -----------------------------------------------
  static const Color lightBgTop = Color(0xFFFBF3E3);
  static const Color lightBgMid = Color(0xFFF3E4C8);
  static const Color lightBgBottom = Color(0xFFEAD6AE);
  static const Color lightCard = Color(0xFFFFFDF7);
  static const Color lightCardBorder = Color(0x668B4513);
  static const Color lightSheet = Color(0xFFFFF8EC);
  static const Color lightAvatarBg = Color(0xFFE7D2AC);
  static const Color lightTextPrimary = Color(0xFF2B1B0E);
  static const Color lightTextSecondary = Color(0xFF5A4327);
  static const Color lightTextMuted = Color(0xFF8A6A45);

  /// Convenience accessor: returns the correct set of surface
  /// colors for the current [ThemeController] value.
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
    starColor: saddleBrown,
  );
}

/// A bundle of surface/text colors for one brightness mode.
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
  });
}

/// The two [ThemeData] objects the app switches between. Both use
/// the same gold/tan/sienna/brown brand identity — only the base
/// surface brightness changes.
class AppTheme {
  AppTheme._();

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.darkBgMid,
        fontFamily: 'Roboto',
        colorScheme: const ColorScheme.dark(
          primary: AppColors.tan,
          secondary: AppColors.sienna,
          surface: AppColors.darkCard,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
      );

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.lightBgMid,
        fontFamily: 'Roboto',
        colorScheme: const ColorScheme.light(
          primary: AppColors.saddleBrown,
          secondary: AppColors.sienna,
          surface: AppColors.lightCard,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: AppColors.lightTextPrimary,
        ),
      );
}
