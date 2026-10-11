import 'dart:collection';

import '../core/config/app_config.dart';
import '../models/physics_state.dart';
import '../models/vec2.dart';

/// One point on the telemetry charts.
class TelemetrySample {
  const TelemetrySample({
    required this.t,
    required this.position,
    this.velocity,
    this.acceleration,
    this.energy,
    this.breakBefore = false,
  });

  final double t;
  final Vec2 position;
  final Vec2? velocity;
  final Vec2? acceleration;
  final EnergyState? energy;
  final bool breakBefore;
}

/// A rolling window of recent tracked states, oldest first.
///
/// Plain Dart (no Riverpod) so it is easy to test. The session controller
/// owns one and bumps a version number whenever it changes, so charts know
/// when to repaint.
class TelemetryBuffer {
  TelemetryBuffer({this.window = AppConfig.telemetryWindow});

  final Duration window;
  final ListQueue<TelemetrySample> _samples = ListQueue();
  bool _gap = false;

  /// Samples in time order. Do not hold on to this across frames.
  Iterable<TelemetrySample> get samples => _samples;

  int get length => _samples.length;
  bool get isEmpty => _samples.isEmpty;
  TelemetrySample? get latest => _samples.isEmpty ? null : _samples.last;

  /// Adds a state. Untracked frames are skipped, so charts show a gap
  /// rather than a jump to zero.
  void add(PhysicsState state) {
    final position = state.position;
    if (!state.tracked || position == null) {
      _gap = true;
      return;
    }

    // Time went backwards: the backend restarted. Start a fresh history.
    if (_samples.isNotEmpty && state.t < _samples.last.t) _samples.clear();

    _samples.add(
      TelemetrySample(
        t: state.t,
        position: position,
        velocity: state.velocity,
        acceleration: state.acceleration,
        energy: state.energy,
        breakBefore: _gap,
      ),
    );
    _gap = false;

    final cutoff = state.t - window.inMicroseconds / 1e6;
    while (_samples.isNotEmpty && _samples.first.t < cutoff) {
      _samples.removeFirst();
    }
  }

  void clear() {
    _samples.clear();
    _gap = false;
  }
}
