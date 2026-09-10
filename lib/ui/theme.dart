import 'package:flutter/material.dart';

/// Plate One's look, ported from the "Organic" design system.
///
/// Warm, plain, unclinical. Nutrition apps default to charts and red warnings;
/// this one should feel like a friend passing you something across the table.
///
/// Two hues carry everything. Sage is the product's own voice — every primary
/// action, every selected state. Terracotta is reserved: it means Pro, or it
/// means "look at this, it might be wrong". Spending it anywhere else would
/// make both meanings quieter.
class PlateColors {
  // Grounds and ink.
  static const cream = Color(0xFFF5EAD8); // page background
  static const card = Color(0xFFEBDDC5); // anything raised off the page
  static const ink = Color(0xFF201E1D);

  /// Secondary text. A warm grey, not a neutral one — a true grey reads as
  /// unconsidered against this ground.
  static const inkSoft = Color(0xFF645C50);

  /// Hairline rules. Translucent rather than a fixed colour so it sits
  /// correctly on both the page and a card.
  static const line = Color(0x29201E1D); // 16% ink

  // Sage — the product's voice.
  static const green = Color(0xFF56633F); // accent-2-700
  static const greenSoft = Color(0xFFE1EECC); // accent-2-200
  static const greenSel = Color(0xFFCCDBB2); // accent-2-300, selected fill
  static const greenPress = Color(0xFF3D472B); // accent-2-800, pressed states

  // Terracotta — Pro, and "check this".
  static const pro = Color(0xFF8C491A); // accent-700
  static const proSoft = Color(0xFFFFE1D0); // accent-200
  static const warn = Color(0xFFB2622D); // accent-600
  static const warnSoft = Color(0xFFFFF2EB); // accent-100

  // Neutral ramp, for the few places that need a step between card and ink.
  static const neutral100 = Color(0xFFF9F4ED);
  static const neutral200 = Color(0xFFEEE7DB);
  static const neutral300 = Color(0xFFDCD3C4);
  static const neutral400 = Color(0xFFC0B6A5);
  static const neutral900 = Color(0xFF2E2B25);

  /// The camera ground. Near-black, but carrying the same warmth as the
  /// rest of the app rather than a flat neutral black.
  static const camera = Color(0xFF12110F);

  /// Chrome drawn on the camera ground. Const rather than a `withValues` call
  /// so the widgets that use it stay const.
  static const onCameraSoft = Color(0xB3F9F4ED); // 70% neutral-100
  static const onCameraFaint = Color(0x4DF9F4ED); // 30% neutral-100
}

/// Spacing scale. Everything in the app lands on one of these.
class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

/// Cards and sheets.
const kRadius = 32.0;

/// Insets, tiles, and the input field — one step tighter than a card.
const kRadiusSmall = 28.0;

/// Buttons, chips and tags are fully round, not merely rounded.
const kPill = 999.0;

const _display = 'Caprasimo';
const _body = 'Figtree';

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: PlateColors.green,
    surface: PlateColors.cream,
  ).copyWith(
    primary: PlateColors.green,
    onPrimary: PlateColors.neutral100,
    secondary: PlateColors.pro,
    surface: PlateColors.cream,
    onSurface: PlateColors.ink,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: PlateColors.cream,
    textTheme: base.textTheme
        .apply(
          fontFamily: _body,
          bodyColor: PlateColors.ink,
          displayColor: PlateColors.ink,
        )
        .copyWith(
          // Caprasimo ships one weight. Asking for w700 anywhere would make
          // Flutter synthesise a bold and smear the display face.
          displaySmall: const TextStyle(
            fontFamily: _display,
            fontWeight: FontWeight.w400,
            fontSize: 30,
            height: 1.1,
            letterSpacing: -0.15,
            color: PlateColors.ink,
          ),
          headlineMedium: const TextStyle(
            fontFamily: _display,
            fontWeight: FontWeight.w400,
            fontSize: 25,
            height: 1.15,
            color: PlateColors.ink,
          ),
          titleLarge: const TextStyle(
            fontFamily: _display,
            fontWeight: FontWeight.w400,
            fontSize: 19,
            height: 1.2,
            color: PlateColors.ink,
          ),
          titleMedium: const TextStyle(
            fontFamily: _body,
            fontSize: 16,
            height: 1.35,
            fontWeight: FontWeight.w600,
            color: PlateColors.ink,
          ),
          bodyLarge: const TextStyle(
            fontFamily: _body,
            fontSize: 15.5,
            height: 1.5,
            color: PlateColors.ink,
          ),
          bodyMedium: const TextStyle(
            fontFamily: _body,
            fontSize: 14,
            height: 1.45,
            color: PlateColors.inkSoft,
          ),
          labelLarge: const TextStyle(
            fontFamily: _body,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.16,
          ),
        ),
    appBarTheme: const AppBarTheme(
      backgroundColor: PlateColors.cream,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: _display,
        fontWeight: FontWeight.w400,
        fontSize: 17,
        height: 1.2,
        color: PlateColors.ink,
      ),
      iconTheme: IconThemeData(color: PlateColors.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PlateColors.green,
        foregroundColor: PlateColors.neutral100,
        disabledBackgroundColor: PlateColors.green.withValues(alpha: 0.45),
        disabledForegroundColor: PlateColors.neutral100.withValues(alpha: 0.75),
        minimumSize: const Size.fromHeight(54),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: _body,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.16,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: PlateColors.ink,
        minimumSize: const Size.fromHeight(54),
        side: const BorderSide(color: PlateColors.line, width: 2),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: _body,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.16,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: PlateColors.green,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: _body,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: PlateColors.neutral900,
      contentTextStyle: const TextStyle(
        fontFamily: _body,
        color: PlateColors.neutral100,
        fontSize: 14.5,
        height: 1.35,
      ),
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
    ),
    dividerTheme: const DividerThemeData(
      color: PlateColors.line,
      thickness: 1,
      space: 1,
    ),
  );
}
