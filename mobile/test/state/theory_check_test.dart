import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/state/telemetry_buffer.dart';
import 'package:hands_on_physics/state/theory_check.dart';

PhysicsState _extras(Map<String, double> extras) =>
    PhysicsState(frameId: 0, t: 0, tracked: true, extras: extras);

/// A ball dropped from rest, sampled at 30 Hz, resting on the floor after.
List<TelemetrySample> _drop({double g = 9.6}) => [
  for (var i = 0; i < 20; i++)
    TelemetrySample(
      t: i / 30,
      position: Vec2(0, 1 - 0.5 * g * math.pow(i / 30, 2)),
      velocity: Vec2(0, -g * i / 30),
      acceleration: Vec2(0, -g),
    ),
  for (var i = 20; i < 30; i++)
    TelemetrySample(
      t: i / 30,
      position: const Vec2(0, 0),
      velocity: Vec2.zero,
      acceleration: Vec2.zero,
    ),
];

/// A pendulum swinging with [period], sampled at 30 Hz for [seconds].
List<TelemetrySample> _swing(double period, {double seconds = 4}) => [
  for (var i = 0; i < seconds * 30; i++)
    TelemetrySample(
      t: i / 30,
      position: Vec2(0.4 + 0.1 * math.sin(2 * math.pi * i / 30 / period), 0),
    ),
];

void main() {
  test('free fall averages only the falling frames', () {
    final check = theoryCheck(
      mode: ExperimentMode.freeFall,
      slidingBody: false,
      latest: null,
      samples: _drop(),
    );
    expect(check.measured, closeTo(9.6, 1e-9));
    expect(check.predicted, standardGravity);
    expect(check.percentOff, closeTo(2.1, 0.1));
  });

  test('a rolling ball on the ramp is predicted at 5/7 g sin θ', () {
    final latest = _extras({'angle_deg': 30});
    final rolling = theoryCheck(
      mode: ExperimentMode.ramp,
      slidingBody: false,
      latest: latest,
      samples: const [],
    );
    final sliding = theoryCheck(
      mode: ExperimentMode.ramp,
      slidingBody: true,
      latest: latest,
      samples: const [],
    );
    expect(sliding.predicted, closeTo(4.905, 1e-3));
    expect(rolling.predicted, closeTo(4.905 * 5 / 7, 1e-3));
    expect(rolling.ready, isFalse);
  });

  test('ramp acceleration is measured along the direction of travel', () {
    final samples = [
      for (var i = 0; i < 5; i++)
        TelemetrySample(
          t: i / 30,
          position: Vec2.zero,
          velocity: const Vec2(0.8, -0.6),
          // 3 m/s² along the motion, plus 1 m/s² across it.
          acceleration: const Vec2(0.8, -0.6) * 3 + const Vec2(0.6, 0.8),
        ),
    ];
    expect(alongPathAcceleration(samples), closeTo(3, 1e-9));
  });

  test('pendulum period comes from the swing and the string length', () {
    final check = theoryCheck(
      mode: ExperimentMode.pendulum,
      slidingBody: false,
      latest: _extras({'length_m': 0.45}),
      samples: _swing(1.35),
    );
    expect(check.measured, closeTo(1.35, 0.05));
    expect(check.predicted, closeTo(1.346, 1e-3));
  });

  test('pendulum period waits for a full swing', () {
    expect(swingPeriod(_swing(1.35, seconds: 0.6)), isNull);
  });

  test('collision compares momentum before and after impact', () {
    final check = theoryCheck(
      mode: ExperimentMode.collision,
      slidingBody: false,
      latest: _extras({'momentum_before': 0.2, 'momentum_after': 0.18}),
      samples: const [],
    );
    expect(check.measured, 0.18);
    expect(check.predicted, 0.2);
    expect(check.percentOff, closeTo(10, 1e-9));
  });

  test('nothing is measured before the backend reports it', () {
    final check = theoryCheck(
      mode: ExperimentMode.collision,
      slidingBody: false,
      latest: null,
      samples: const [],
    );
    expect(check.ready, isFalse);
    expect(check.percentOff, isNull);
    expect(check.waitingFor, isNotEmpty);
  });
}
