import 'package:flutter/material.dart';

import 'tokens.dart';

/// Light (vellum) and dark (graphite) themes built only from [tokens.dart].
///
/// The Material colour scheme is deliberately neutral: primary is graphite
/// on light and vellum on dark. Physics colours never enter the scheme, so
/// no Material widget can accidentally paint chrome green or red.
abstract final class AppTheme {
  static ThemeData light() => _build(
    brightness: Brightness.light,
    background: AppColors.vellum,
    surface: AppColors.vellumRaised,
    ink: AppColors.graphite,
    inkMuted: AppColors.inkMuted,
    rule: AppColors.rule,
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    background: AppColors.graphiteDeep,
    surface: AppColors.graphiteRaised,
    ink: AppColors.vellum,
    inkMuted: AppColors.inkMutedDark,
    rule: AppColors.ruleDark,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color ink,
    required Color inkMuted,
    required Color rule,
  }) {
    final accent = brightness == Brightness.dark
        ? AppColors.instrumentAccentDark
        : AppColors.instrumentAccent;
    final onAccent = brightness == Brightness.dark
        ? AppColors.graphiteDeep
        : Colors.white;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: onAccent,
      secondary: inkMuted,
      onSecondary: background,
      error: ink,
      onError: background,
      surface: background,
      onSurface: ink,
      onSurfaceVariant: inkMuted,
      surfaceContainerLowest: background,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface,
      surfaceContainerHighest: surface,
      outline: rule,
      outlineVariant: rule,
    );

    TextStyle ink_(TextStyle s) => s.copyWith(color: ink);
    TextStyle muted(TextStyle s) => s.copyWith(color: inkMuted);

    final textTheme = TextTheme(
      displaySmall: ink_(AppType.display),
      headlineSmall: ink_(AppType.title),
      titleLarge: ink_(AppType.title),
      titleMedium: ink_(AppType.bodyStrong),
      bodyLarge: ink_(AppType.body),
      bodyMedium: ink_(AppType.body),
      bodySmall: muted(AppType.caption),
      labelLarge: ink_(AppType.label),
      labelMedium: ink_(AppType.label),
      labelSmall: muted(AppType.caption),
    );

    const buttonPadding = EdgeInsets.symmetric(
      horizontal: AppSpace.xl,
      vertical: AppSpace.md + 2,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: AppType.family,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: DividerThemeData(color: rule, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: ink_(AppType.title),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.instrumentAccent,
          foregroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadii.controlAll,
          ),
          padding: buttonPadding,
          textStyle: AppType.label.copyWith(fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: BorderSide(color: rule, width: 1.5),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadii.controlAll,
          ),
          padding: buttonPadding,
          textStyle: AppType.label.copyWith(fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadii.controlAll,
          ),
          textStyle: AppType.label.copyWith(fontSize: 15),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: ink),
      ),
      chipTheme: ChipThemeData(
        shape: AppRadii.pill,
        side: BorderSide(color: rule),
        backgroundColor: surface,
        labelStyle: ink_(AppType.label),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.panelAll,
          side: BorderSide(color: rule),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
        showDragHandle: true,
        dragHandleColor: rule,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        labelStyle: muted(AppType.label),
        border: OutlineInputBorder(
          borderRadius: AppRadii.panelAll,
          borderSide: BorderSide(color: rule),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.panelAll,
          borderSide: BorderSide(color: rule),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadii.panelAll,
          borderSide: const BorderSide(
            color: AppColors.instrumentAccent,
            width: 1.5,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? background : inkMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? ink : surface,
        ),
        trackOutlineColor: WidgetStatePropertyAll(rule),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: AppType.body.copyWith(color: background),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.panelAll),
      ),
    );
  }
}
