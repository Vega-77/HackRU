import 'package:flutter/material.dart';

/// Design tokens: the single source of truth for colour, type, shape,
/// spacing and motion. Screens never hard-code these values.
///
/// The core rule: colour means a physical quantity. The four physics
/// colours below are used for arrows, chart lines, readout labels and
/// energy bars, and for nothing else. All other chrome is neutral.

abstract final class AppColors {
  // Neutral chrome, cool drafting-film tones.
  static const vellum = Color(0xFFEEF1F3);
  static const vellumRaised = Color(0xFFF8FAFB);
  static const graphite = Color(0xFF1E2328);
  static const graphiteDeep = Color(0xFF15191D);
  static const graphiteRaised = Color(0xFF20262C);
  static const rule = Color(0xFFC9D1D8);
  static const ruleDark = Color(0xFF333B43);
  static const inkMuted = Color(0xFF5B6670);
  static const inkMutedDark = Color(0xFF9AA6B0);

  // Burnished copper marks the app's controls and active selection. Physics
  // colours stay reserved for measured quantities.
  static const instrumentAccent = Color(0xFFA44724);
  static const instrumentAccentDark = Color(0xFFE9A480);

  // Physics quantities. Do not use these for UI chrome.
  static const velocity = Color(0xFF2FBF71);
  static const acceleration = Color(0xFFE5484D);
  static const forceNet = Color(0xFF3E7BFA);
  static const forceComponent = Color(0xFFF2C230);

  // Energy bars reuse the quantity colours: kinetic goes with velocity,
  // gravitational potential with the gravity component. Thermal is
  // energy that has left the system, so it stays neutral.
  static const kinetic = velocity;
  static const potential = forceComponent;
  static const thermal = Color(0xFF8A96A1);

  /// Translucent graphite for chrome floating over the camera feed.
  static const scrim = Color(0xCC15191D);
}

/// Archivo is a variable font with width (62 to 125) and weight axes.
/// Wide cuts are for titles, condensed cuts with tabular figures for live
/// numbers, and italic for physics variables like v, a and F.
abstract final class AppType {
  static const family = 'Archivo';

  static TextStyle _archivo({
    required double size,
    required double weight,
    double width = 100,
    double height = 1.3,
    double letterSpacing = 0,
    bool tabular = false,
    bool italic = false,
  }) => TextStyle(
    fontFamily: family,
    fontSize: size,
    height: height,
    letterSpacing: letterSpacing,
    // fontWeight is the fallback when variations are unsupported.
    fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    fontVariations: [FontVariation.weight(weight), FontVariation.width(width)],
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );

  /// Screen titles. Wide and heavy, set tight.
  static final display = _archivo(
    size: 34,
    weight: 720,
    width: 125,
    height: 1.05,
    letterSpacing: -0.6,
  );

  /// Section and sheet titles.
  static final title = _archivo(
    size: 20,
    weight: 650,
    width: 115,
    height: 1.15,
  );

  static final body = _archivo(size: 15, weight: 400, height: 1.45);

  static final bodyStrong = _archivo(size: 15, weight: 580, height: 1.45);

  /// Buttons, chips, small labels. Sentence case, never all caps.
  static final label = _archivo(size: 13, weight: 560, width: 105, height: 1.2);

  static final caption = _archivo(size: 12, weight: 450, height: 1.3);

  /// Big live numbers in the telemetry sheet.
  static final readout = _archivo(
    size: 30,
    weight: 620,
    width: 75,
    height: 1,
    tabular: true,
  );

  /// Small live numbers: units, axis ticks, latency.
  static final readoutSmall = _archivo(
    size: 13,
    weight: 520,
    width: 80,
    height: 1.1,
    tabular: true,
  );

  /// A physics variable symbol such as v or a, in textbook italic.
  static final variable = _archivo(
    size: 16,
    weight: 560,
    width: 100,
    height: 1,
    italic: true,
  );
}

/// Instrument panels use [panel]. Primary controls use [control], while
/// compact selectors can use the pill shape.
abstract final class AppRadii {
  static const double panel = 14;
  static const double control = 10;
  static const BorderRadius panelAll = BorderRadius.all(Radius.circular(panel));
  static const BorderRadius controlAll = BorderRadius.all(
    Radius.circular(control),
  );
  static const BorderRadius sheetTop = BorderRadius.vertical(
    top: Radius.circular(panel),
  );
  static const StadiumBorder pill = StadiumBorder();
}

abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

abstract final class AppMotion {
  static const Duration quick = Duration(milliseconds: 150);
  static const Duration standard = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 520);
  static const Curve ease = Curves.easeOutCubic;

  /// Fraction of the remaining distance an arrow closes per 60 Hz tick.
  /// About 0.25 settles in roughly 150 ms, which hides jitter without lag.
  static const double arrowSmoothing = 0.25;

  /// The same for the object marker. Faster than the arrows, so the
  /// marker stays on the object in the camera feed.
  static const double markerSmoothing = 0.5;
}
