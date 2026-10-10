import 'dart:async';
import 'dart:math' as math;

import '../../models/experiment_mode.dart';
import '../../models/physics_state.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';

/// Synthetic, physically consistent states for every experiment mode.
///
/// Used for demo mode (no backend), for the home screen's mini diagrams,
/// and in tests. [sample] is a pure function of time, so the same `t`
/// always gives the same state. Each experiment loops forever.
///
/// World coordinates are SI with y up and the origin at the bottom-left of
/// the frame. The world is 0.65 m tall regardless of frame size, so the
/// motion always fits on screen.
abstract final class MockPhysics {
  static const double g = 9.81;
  static const double worldHeightM = 0.65;

  static PhysicsState sample(
    ExperimentMode mode,
    double t, {
    FrameSize frameSize = const FrameSize(320, 240),
    double massKg = 0.1,
    int seq = 0,
  }) {
    final m = massKg;
    final world = switch (mode) {
      ExperimentMode.ramp => _ramp(t, m),
      ExperimentMode.freeFall => _freeFall(t, m),
      ExperimentMode.pendulum => _pendulum(t, m),
      ExperimentMode.collision => _collision(t, m),
    };

    // World metres → frame pixels (y flips).
    final pxPerM = frameSize.height / worldHeightM;
    final pixel = Vec2(
      world.position.x * pxPerM,
      frameSize.height - world.position.y * pxPerM,
    );
    const half = 9.0;

    return PhysicsState(
      seq: seq,
      t: t,
      tracked: true,
      pixel: pixel,
      bbox: PixelRect(pixel.x - half, pixel.y - half, half * 2, half * 2),
      position: world.position,
      velocity: world.velocity,
      acceleration: world.acceleration,
      forces: [
        ...world.forces,
        ForceVector('net', world.acceleration * m),
      ],
      energy: world.energy,
      extras: world.extras,
    );
  }

  /// A block sliding down a 25° ramp with friction.
  static _World _ramp(double t, double m) {
    const theta = 25 * math.pi / 180;
    const mu = 0.15;
    const length = 0.62; // metres of travel before looping
    const start = Vec2(0.08, 0.52);
    final down = Vec2(math.cos(theta), -math.sin(theta)); // along the ramp
    final outward = Vec2(math.sin(theta), math.cos(theta)); // normal

    final a = g * (math.sin(theta) - mu * math.cos(theta));
    final tEnd = math.sqrt(2 * length / a);
    final local = _loop(t, tEnd, hold: 0.5);
    final moving = local < tEnd;
    final tt = math.min(local, tEnd);

    final s = 0.5 * a * tt * tt;
    final speed = moving ? a * tt : 0.0;
    final position = start + down * s;

    final weight = m * g;
    final normal = weight * math.cos(theta);
    final friction = moving ? mu * normal : weight * math.sin(theta);
    final bottomY = start.y - length * math.sin(theta);
    // At the end stop the block's kinetic energy turns into heat.
    final vEnd = a * tEnd;
    final stopLoss = moving ? 0.0 : 0.5 * m * vEnd * vEnd;

    return _World(
      position: position,
      velocity: down * speed,
      acceleration: moving ? down * a : Vec2.zero,
      forces: [
        ForceVector('gravity', Vec2(0, -weight)),
        ForceVector('normal', outward * normal),
        ForceVector('friction', -down * friction),
        ForceVector('gravity_parallel', down * (weight * math.sin(theta))),
        ForceVector(
          'gravity_perpendicular',
          -outward * (weight * math.cos(theta)),
        ),
      ],
      energy: EnergyState(
        kinetic: 0.5 * m * speed * speed,
        potential: weight * (position.y - bottomY),
        thermal: mu * normal * s + stopLoss,
      ),
      extras: const {'angle_deg': 25, 'mu': mu},
    );
  }

  /// A ball launched up and to the right (projectile motion).
  static _World _freeFall(double t, double m) {
    const start = Vec2(0.06, 0.18);
    const v0 = Vec2(0.55, 2.4);
    const floor = 0.04;
    // Time to come back down to the floor.
    final tEnd = (v0.y + math.sqrt(v0.y * v0.y + 2 * g * (start.y - floor))) / g;
    final local = _loop(t, tEnd, hold: 0.4);
    final landed = local >= tEnd;
    final tt = math.min(local, tEnd);

    final position = Vec2(
      start.x + v0.x * tt,
      start.y + v0.y * tt - 0.5 * g * tt * tt,
    );
    final flying = Vec2(v0.x, v0.y - g * tt);
    final velocity = landed ? Vec2.zero : flying;
    final weight = m * g;

    return _World(
      position: position,
      velocity: velocity,
      acceleration: landed ? Vec2.zero : const Vec2(0, -g),
      forces: [
        ForceVector('gravity', Vec2(0, -weight)),
        if (landed) ForceVector('normal', Vec2(0, weight)),
      ],
      energy: EnergyState(
        kinetic: 0.5 * m * velocity.dot(velocity),
        potential: weight * (position.y - floor),
        // The landing turns the ball's kinetic energy into heat and sound.
        thermal: landed ? 0.5 * m * flying.dot(flying) : 0,
      ),
      extras: const {},
    );
  }

  /// A pendulum released from 35° on a 0.45 m string.
  ///
  /// At 35° the small-angle formula is visibly wrong (energy drifts by a
  /// few percent), so one full swing is integrated exactly once with RK4
  /// and looked up by time.
  static _World _pendulum(double t, double m) {
    final (:theta, :thetaDot) = _PendulumTable.instance.at(t);
    const pivot = _PendulumTable.pivot;
    const length = _PendulumTable.length;
    final thetaDdot = -(g / length) * math.sin(theta);

    final tangent = Vec2(math.cos(theta), math.sin(theta));
    final towardPivot = Vec2(-math.sin(theta), math.cos(theta));
    final position = pivot + Vec2(math.sin(theta), -math.cos(theta)) * length;
    final velocity = tangent * (length * thetaDot);
    final acceleration = tangent * (length * thetaDdot) +
        towardPivot * (length * thetaDot * thetaDot);

    final weight = m * g;
    final tension = m * (g * math.cos(theta) + length * thetaDot * thetaDot);

    return _World(
      position: position,
      velocity: velocity,
      acceleration: acceleration,
      forces: [
        ForceVector('gravity', Vec2(0, -weight)),
        ForceVector('tension', towardPivot * tension),
      ],
      energy: EnergyState(
        kinetic: 0.5 * m * velocity.dot(velocity),
        potential: weight * length * (1 - math.cos(theta)),
        thermal: 0,
      ),
      extras: {'angle_deg': theta * 180 / math.pi},
    );
  }

  /// A cart rolling into a parked cart twice its mass, elastically.
  /// We track the first cart, which bounces back at a third of its speed.
  static _World _collision(double t, double m) {
    const y = 0.06;
    const x0 = 0.06;
    const u = 0.9; // initial speed, m/s
    const decel = 0.25; // rolling friction, m/s²
    const contactX = 0.5;
    const impact = 0.06; // seconds the carts are in contact

    // Approach phase: x = x0 + u t - ½ d t², solved for contactX.
    final tHit = (u - math.sqrt(u * u - 2 * decel * (contactX - x0))) / decel;
    final vHit = u - decel * tHit;
    final vAfter = -vHit / 3; // elastic, m against 2m
    final tStop = impact + vAfter.abs() / decel;
    final local = _loop(t, tHit + tStop, hold: 0.6);

    final double x;
    final double v;
    final double a;
    var contactForce = 0.0;
    if (local < tHit) {
      x = x0 + u * local - 0.5 * decel * local * local;
      v = u - decel * local;
      a = -decel;
    } else if (local < tHit + impact) {
      // During contact, speed changes linearly from vHit to vAfter.
      final f = (local - tHit) / impact;
      x = contactX;
      v = vHit + (vAfter - vHit) * f;
      a = (vAfter - vHit) / impact;
      contactForce = m * a;
    } else {
      final tt = math.min(local - tHit - impact, vAfter.abs() / decel);
      x = contactX + vAfter * tt + 0.5 * decel * tt * tt;
      v = vAfter + decel * tt;
      a = v.abs() < 1e-6 ? 0 : decel;
    }

    final frictionX = v.abs() < 1e-6 ? 0.0 : -v.sign * m * decel;
    final travelled = local < tHit
        ? x - x0
        : (contactX - x0) + (contactX - x).abs();

    return _World(
      position: Vec2(x, y),
      velocity: Vec2(v, 0),
      acceleration: Vec2(a, 0),
      forces: [
        ForceVector('friction', Vec2(frictionX, 0)),
        if (contactForce != 0) ForceVector('normal', Vec2(contactForce, 0)),
      ],
      energy: EnergyState(
        kinetic: 0.5 * m * v * v,
        potential: 0,
        thermal: m * decel * travelled,
      ),
      extras: {'momentum': m * v},
    );
  }

  /// Time within one loop of an experiment that runs for [duration] and
  /// then holds its final pose for [hold] seconds.
  static double _loop(double t, double duration, {required double hold}) =>
      t % (duration + hold);
}

/// One period of an undamped pendulum, sampled every millisecond.
class _PendulumTable {
  _PendulumTable._() {
    const dt = _dt;
    const k = MockPhysics.g / length;
    double f(double th) => -k * math.sin(th); // angular acceleration

    var th = amplitude;
    var w = 0.0;
    var wasRising = false;
    while (true) {
      _theta.add(th);
      _thetaDot.add(w);
      // RK4 step for th' = w, w' = f(th).
      final k1t = w, k1w = f(th);
      final k2t = w + k1w * dt / 2, k2w = f(th + k1t * dt / 2);
      final k3t = w + k2w * dt / 2, k3w = f(th + k2t * dt / 2);
      final k4t = w + k3w * dt, k4w = f(th + k3t * dt);
      th += (k1t + 2 * k2t + 2 * k3t + k4t) * dt / 6;
      w += (k1w + 2 * k2w + 2 * k3w + k4w) * dt / 6;
      // One period ends when the bob is back at the start, turning around.
      if (w > 0) wasRising = true;
      if (wasRising && w <= 0) break;
    }
  }

  static final instance = _PendulumTable._();

  static const pivot = Vec2(0.42, 0.6);
  static const length = 0.45;
  static const amplitude = 35 * math.pi / 180;
  static const _dt = 0.001;

  final List<double> _theta = [];
  final List<double> _thetaDot = [];

  ({double theta, double thetaDot}) at(double t) {
    final period = _theta.length * _dt;
    final x = (t % period) / _dt;
    final i = x.floor() % _theta.length;
    final j = (i + 1) % _theta.length;
    final f = x - x.floor();
    return (
      theta: _theta[i] + (_theta[j] - _theta[i]) * f,
      thetaDot: _thetaDot[i] + (_thetaDot[j] - _thetaDot[i]) * f,
    );
  }
}

class _World {
  const _World({
    required this.position,
    required this.velocity,
    required this.acceleration,
    required this.forces,
    required this.energy,
    required this.extras,
  });

  final Vec2 position;
  final Vec2 velocity;
  final Vec2 acceleration;
  final List<ForceVector> forces;
  final EnergyState energy;
  final Map<String, double> extras;
}

/// Emits [MockPhysics.sample] at [hz], timed from when you subscribe.
Stream<PhysicsState> mockPhysicsStream({
  required ExperimentMode mode,
  required FrameSize frameSize,
  required double massKg,
  int hz = 30,
}) {
  final clock = Stopwatch()..start();
  var seq = 0;
  return Stream<PhysicsState>.periodic(
    Duration(microseconds: 1000000 ~/ hz),
    (_) => MockPhysics.sample(
      mode,
      clock.elapsedMicroseconds / 1e6,
      frameSize: frameSize,
      massKg: massKg,
      seq: seq++,
    ),
  );
}
