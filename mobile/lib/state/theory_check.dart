import 'dart:math' as math;

import '../models/experiment_mode.dart';
import '../models/physics_state.dart';
import 'telemetry_buffer.dart';

/// Standard gravity, the same value the backend uses.
const double standardGravity = 9.81;

/// One measured quantity next to what the textbook model predicts for it.
///
/// Worked out on the phone from what the backend already sends, so a
/// student sees straight away whether the run agrees with theory.
class TheoryCheck {
  const TheoryCheck({
    required this.symbol,
    required this.quantity,
    required this.model,
    required this.unit,
    required this.spokenUnit,
    this.measured,
    this.predicted,
    this.waitingFor = '',
  });

  /// Textbook symbol of the compared quantity, such as `a` or `T`.
  final String symbol;
  final String quantity;

  /// The prediction as a formula, such as `a = g sin θ`.
  final String model;
  final String unit;
  final String spokenUnit;
  final double? measured;
  final double? predicted;

  /// What the student should do while either number is missing.
  final String waitingFor;

  bool get ready => measured != null && predicted != null;

  /// How far the measurement is from the prediction, in percent.
  double? get percentOff {
    final m = measured, p = predicted;
    if (m == null || p == null || p == 0) return null;
    return (m - p).abs() / p.abs() * 100;
  }
}

/// Compares the latest run with the model for [mode].
///
/// Accelerations are averaged over the moving part of the run in [samples],
/// because a single frame is noisy and the object spends time at rest.
TheoryCheck theoryCheck({
  required ExperimentMode mode,
  required bool slidingBody,
  required PhysicsState? latest,
  required Iterable<TelemetrySample> samples,
}) {
  final extras = latest?.extras ?? const <String, double>{};
  switch (mode) {
    case ExperimentMode.freeFall:
      return TheoryCheck(
        symbol: 'a',
        quantity: 'Acceleration while falling',
        model: 'a = g',
        unit: 'm/s²',
        spokenUnit: 'metres per second squared',
        measured: fallingAcceleration(samples),
        predicted: standardGravity,
        waitingFor: 'Drop the object to measure it.',
      );
    case ExperimentMode.ramp:
      final angle = extras['angle_deg']?.abs();
      // A solid ball puts 2/7 of its energy into spinning, so it speeds up
      // at only 5/7 of a frictionless block's rate.
      final factor = slidingBody ? 1.0 : 5 / 7;
      return TheoryCheck(
        symbol: 'a',
        quantity: 'Acceleration along the ramp',
        model: slidingBody ? 'a = g sin θ' : 'a = 5/7 g sin θ',
        unit: 'm/s²',
        spokenUnit: 'metres per second squared',
        measured: alongPathAcceleration(samples),
        predicted: angle == null
            ? null
            : factor * standardGravity * math.sin(angle * math.pi / 180),
        waitingFor: 'Let the object run down the ramp.',
      );
    case ExperimentMode.pendulum:
      final length = extras['length_m'];
      return TheoryCheck(
        symbol: 'T',
        quantity: 'Period of one swing',
        model: 'T = 2π √(L / g)',
        unit: 's',
        spokenUnit: 'seconds',
        measured: swingPeriod(samples),
        predicted: length == null || length <= 0
            ? null
            : 2 * math.pi * math.sqrt(length / standardGravity),
        waitingFor: 'Let it swing back and forth twice.',
      );
    case ExperimentMode.collision:
      return TheoryCheck(
        symbol: 'p',
        quantity: 'Total momentum after impact',
        model: 'p after = p before',
        unit: 'kg m/s',
        spokenUnit: 'kilogram metres per second',
        measured: extras['momentum_after'],
        predicted: extras['momentum_before'],
        waitingFor: 'Roll one object into the other.',
      );
  }
}

/// Below this speed the object counts as at rest, in m/s.
const double _movingSpeed = 0.1;

/// Fewest moving samples worth averaging.
const int _minSamples = 3;

/// Mean downward acceleration while the object is falling, in m/s².
double? fallingAcceleration(Iterable<TelemetrySample> samples) {
  final values = [
    for (final s in samples)
      if (s.velocity case final v? when v.y < -_movingSpeed)
        if (s.acceleration case final a?) -a.y,
  ];
  return _mean(values);
}

/// Mean size of the acceleration along the direction of travel, in m/s².
///
/// Uses the size so a ball rolled up the ramp and back counts both ways.
double? alongPathAcceleration(Iterable<TelemetrySample> samples) {
  final values = [
    for (final s in samples)
      if (s.velocity case final v? when v.length > _movingSpeed)
        if (s.acceleration case final a?) a.dot(v.normalized).abs(),
  ];
  return _mean(values);
}

/// Time for one full swing, from how often the object crosses the middle
/// of its horizontal range. Null until it has crossed three times.
double? swingPeriod(Iterable<TelemetrySample> samples) {
  final list = samples.toList(growable: false);
  if (list.length < 2 * _minSamples) return null;
  final centre =
      list.map((s) => s.position.x).reduce((a, b) => a + b) / list.length;
  final amplitude = list
      .map((s) => (s.position.x - centre).abs())
      .reduce(math.max);
  if (amplitude < 0.02) return null;

  // A band around the centre stops tracking jitter counting as a crossing.
  final band = 0.2 * amplitude;
  final crossings = <double>[];
  var side = 0;
  for (final s in list) {
    final offset = s.position.x - centre;
    final now = offset > band
        ? 1
        : offset < -band
        ? -1
        : 0;
    if (now == 0) continue;
    if (side != 0 && now != side) crossings.add(s.t);
    side = now;
  }
  // Crossings alternate direction, and the band shifts each direction's
  // timing the opposite way, so measure over whole swings only.
  final halves = (crossings.length - 1) ~/ 2 * 2;
  if (halves < 2) return null;
  return (crossings[halves] - crossings[0]) / (halves / 2);
}

double? _mean(List<double> values) {
  if (values.length < _minSamples) return null;
  return values.reduce((a, b) => a + b) / values.length;
}
