import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/calibration/mass_steps.dart';

void main() {
  group('MassSteps', () {
    test('uses fine steps for light objects and coarse ones for heavy', () {
      expect(MassSteps.up(0.1), 0.11);
      expect(MassSteps.up(0.5), 0.55);
      expect(MassSteps.up(2), 2.25);
      expect(MassSteps.down(0.1), 0.09);
      expect(MassSteps.down(0.5), 0.45);
      expect(MassSteps.down(2), 1.75);
    });

    test('changes step size exactly at the boundaries', () {
      expect(MassSteps.up(0.19), 0.2);
      expect(MassSteps.up(0.2), 0.25);
      expect(MassSteps.down(0.25), 0.2);
      expect(MassSteps.down(0.2), 0.19);
      expect(MassSteps.up(1), 1.25);
      expect(MassSteps.down(1.25), 1);
      expect(MassSteps.down(1), 0.95);
    });

    test('snaps an off-grid mass back onto the grid', () {
      expect(MassSteps.up(0.123), 0.13);
      expect(MassSteps.down(0.123), 0.12);
    });

    test('never drifts after many taps', () {
      var kg = 0.1;
      for (var i = 0; i < 30; i++) {
        kg = MassSteps.up(kg);
      }
      for (var i = 0; i < 30; i++) {
        kg = MassSteps.down(kg);
      }
      expect(kg, 0.1);
    });

    test('stays within the limits', () {
      expect(MassSteps.down(MassSteps.minKg), MassSteps.minKg);
      expect(MassSteps.up(MassSteps.maxKg), MassSteps.maxKg);
      expect(MassSteps.canGoDown(MassSteps.minKg), isFalse);
      expect(MassSteps.canGoUp(MassSteps.maxKg), isFalse);
      expect(MassSteps.canGoUp(0.1), isTrue);
      expect(MassSteps.canGoDown(0.1), isTrue);
    });

    test('formats grams below a kilogram and kilograms from one up', () {
      expect(MassSteps.format(0.1), '100 g');
      expect(MassSteps.format(0.01), '10 g');
      expect(MassSteps.format(1), '1 kg');
      expect(MassSteps.format(1.5), '1.5 kg');
      expect(MassSteps.format(1.25), '1.25 kg');
    });
  });
}
