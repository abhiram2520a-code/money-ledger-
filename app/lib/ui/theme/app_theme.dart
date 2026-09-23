import 'package:flutter/material.dart';

import 'palette.dart';
import 'tokens.dart';

/// The app's Material 3 themes.
///
/// The seed is a deep, slightly desaturated teal-green. The brief for this
/// palette was blunt: the app asks permission to read a stranger's bank
/// messages, so it has to look like a bank's own utility and not like a
/// giveaway. That rules out saturated purple/pink gradients, neon accents and
/// anything that reads as "growth hack". Teal-green is the colour Indian
/// banking surfaces already use for "safe", and it is far enough from the
/// alert colours that a red badge still means something.
abstract final class AppTheme {
  /// Deep teal. Everything else is derived from it by Material's tonal
  /// algorithm, so light and dark stay in step automatically.
  static const Color seed = Color(0xFF0F5F52);

  static ThemeData light() => _build(Brightness.light, LedgerPalette.light);

  static ThemeData dark() => _build(Brightness.dark, LedgerPalette.dark);

  static ThemeData _build(Brightness brightness, LedgerPalette palette) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final Typography typography = Typography.material2021(colorScheme: scheme);
    final TextTheme text = _textTheme(
      brightness == Brightness.dark ? typography.white : typography.black,
      scheme,
    );

    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      extensions: <ThemeExtension<dynamic>>[palette],
      textTheme: text,
      appBarTheme: AppBarThemeData(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: Radii.cardBorder),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: Insets.page),
        minVerticalPadding: Insets.sm,
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        shape: const RoundedRectangleBorder(borderRadius: Radii.pill),
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.secondaryContainer,
        showCheckmark: false,
        labelStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: const RoundedRectangleBorder(borderRadius: Radii.fieldBorder),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: const RoundedRectangleBorder(borderRadius: Radii.fieldBorder),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheetBorder),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        shape: const RoundedRectangleBorder(borderRadius: Radii.fieldBorder),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: palette.chartTrack,
        linearMinHeight: 6,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }

  /// Tightens Material's defaults a little. Financial figures are read, not
  /// skimmed: headline numbers get negative tracking so a long rupee amount
  /// still fits on one line at 320dp, and body text keeps generous line height
  /// because the disclosure screen is a paragraph a reviewer has to read.
  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    return base.copyWith(
      displaySmall: base.displaySmall?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -1,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelSmall: base.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
    ).apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );
  }

  /// A monospace-ish tabular style for amounts that sit in a column. Digits do
  /// not jitter between rows, which is the difference between a ledger and a
  /// list of numbers.
  static TextStyle tabular(TextStyle? base) =>
      (base ?? const TextStyle()).copyWith(
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );
}
