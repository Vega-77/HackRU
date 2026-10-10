import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/experiment/widgets/arrow_scale.dart';
import 'package:hands_on_physics/models/vec2.dart';

void main() {
  const scale = ArrowScale(unit: 1, weightN: 0.981); // a 100 g object

  group('ArrowScale', () {
    test('velocity and acceleration are linear below the knee', () {
      expect(scale.velocity(const Vec2(0.5, 0)), 60);
      expect(scale.acceleration(const Vec2(0, -2)), 60);
    });

    test('long arrows ease towards the maximum without passing it', () {
      final fast = scale.velocity(const Vec2(5, 0));
      final faster = scale.velocity(const Vec2(50, 0));
      expect(fast, greaterThan(140));
      expect(faster, greaterThan(fast));
      expect(faster, lessThanOrEqualTo(scale.maxPx));
    });

    test('the weight is the reference force length', () {
      final lengths = scale.forces({'gravity': const Vec2(0, -0.981)});
      expect(lengths['gravity'], closeTo(ArrowScale.weightPx, 1e-9));
    });

    test('forces shrink together so the diagram still adds up', () {
      final lengths = scale.forces({
        'gravity': const Vec2(0, -0.981),
        'applied': const Vec2(9.81, 0), // ten times the weight
      });
      expect(lengths['applied'], closeTo(scale.maxPx, 1e-9));
      expect(lengths['applied']! / lengths['gravity']!, closeTo(10, 1e-9));
    });

    test('scales with the view', () {
      final small = ArrowScale.forView(const Size(195, 400), massKg: 0.1);
      expect(small.unit, 0.5);
      expect(small.velocity(const Vec2(0.5, 0)), 30);
    });

    test('hides arrows too short to read', () {
      expect(scale.visible(2), isFalse);
      expect(scale.visible(10), isTrue);
    });
  });
}
