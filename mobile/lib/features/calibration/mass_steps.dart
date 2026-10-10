/// The mass stepper's steps: fine for light objects, coarse for heavy ones.
///
/// * below 200 g: 10 g steps (a marble, a toy car)
/// * 200 g to 1 kg: 50 g steps (a cart, a water bottle)
/// * above 1 kg: 250 g steps
///
/// Works in whole grams so repeated taps never drift (0.1 + 0.01 in
/// floating point is not exactly 0.11).
abstract final class MassSteps {
  static const minKg = 0.01;
  static const maxKg = 10.0;

  static double up(double kg) {
    final g = _grams(kg);
    final step = g < 200 ? 10 : (g < 1000 ? 50 : 250);
    return _kg((g ~/ step + 1) * step);
  }

  static double down(double kg) {
    final g = _grams(kg);
    final step = g <= 200 ? 10 : (g <= 1000 ? 50 : 250);
    // Round up to the grid first, so 123 g steps down to 120 g, not 113 g.
    return _kg(((g + step - 1) ~/ step - 1) * step);
  }

  static bool canGoUp(double kg) => _grams(kg) < _grams(maxKg);
  static bool canGoDown(double kg) => _grams(kg) > _grams(minKg);

  /// "100 g" below a kilogram, "1.25 kg" from one up.
  static String format(double kg) {
    final g = _grams(kg);
    if (g < 1000) return '$g g';
    final text = (g / 1000).toStringAsFixed(2);
    // 1.50 → 1.5, 2.00 → 2
    return '${text.replaceFirst(RegExp(r'\.?0+$'), '')} kg';
  }

  static int _grams(double kg) => (kg * 1000).round();

  static double _kg(int grams) =>
      grams.clamp(_grams(minKg), _grams(maxKg)) / 1000;
}
