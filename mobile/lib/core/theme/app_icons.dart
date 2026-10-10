import 'package:flutter/widgets.dart';

/// The app's icons: Phosphor, Regular weight only (MIT, see
/// assets/fonts/Phosphor-LICENSE.txt).
///
/// We bundle the icon font ourselves instead of depending on the
/// phosphor_flutter package, whose 2.1.0 release no longer compiles on
/// current Flutter (it extends IconData, which is now a final class).
/// To add an icon, find its code point in Phosphor's regular icon list
/// (phosphoricons.com, or phosphor_icons_regular.dart in that package).
abstract final class AppIcons {
  static const arrowClockwise = IconData(0xe036, fontFamily: _family);
  static const arrowLeft = IconData(0xe058, fontFamily: _family);
  static const arrowRight = IconData(0xe06c, fontFamily: _family);
  static const broadcast = IconData(0xe0f2, fontFamily: _family);
  static const cameraSlash = IconData(0xe110, fontFamily: _family);
  static const caretDown = IconData(0xe136, fontFamily: _family);
  static const caretLeft = IconData(0xe138, fontFamily: _family);
  static const caretRight = IconData(0xe13a, fontFamily: _family);
  static const cellSignalSlash = IconData(0xe14c, fontFamily: _family);
  static const check = IconData(0xe182, fontFamily: _family);
  static const checkCircle = IconData(0xe184, fontFamily: _family);
  static const circle = IconData(0xe18a, fontFamily: _family);
  static const crosshair = IconData(0xe1d6, fontFamily: _family);
  static const flask = IconData(0xe79e, fontFamily: _family);
  static const gear = IconData(0xe270, fontFamily: _family);
  static const info = IconData(0xe2ce, fontFamily: _family);
  static const minus = IconData(0xe32a, fontFamily: _family);
  static const pause = IconData(0xe39e, fontFamily: _family);
  static const play = IconData(0xe3d0, fontFamily: _family);
  static const plugs = IconData(0xeb56, fontFamily: _family);
  static const plus = IconData(0xe3d4, fontFamily: _family);
  static const ruler = IconData(0xe6b8, fontFamily: _family);
  static const sliders = IconData(0xe432, fontFamily: _family);
  static const target = IconData(0xe47c, fontFamily: _family);
  static const warning = IconData(0xe4e0, fontFamily: _family);
  static const wifiHigh = IconData(0xe4ea, fontFamily: _family);
  static const wifiSlash = IconData(0xe4f2, fontFamily: _family);
  static const x = IconData(0xe4f6, fontFamily: _family);

  static const _family = 'PhosphorRegular';
}
