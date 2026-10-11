import 'dart:math' as math;

import '../../../models/experiment_mode.dart';
import '../../../models/physics_state.dart';
import '../../../models/session_config.dart';
import '../../../models/vec2.dart';

/// Simulated, physically consistent states for every experiment mode, for
/// the home screen's previews. The experiment itself always measures with
/// the backend.
///
/// [sample] is a pure function of time, so the same `t` always gives the
/// same state. Each experiment loops forever.
///
/// World coordinates are SI with y up and the origin at the bottom-left of
/// the frame. The world is 0.65 m tall regardless of frame size, so the
/// motion always fits on screen.
abstract final class PreviewPhysics {
  static const double g = 9.81;
  static const double worldHeightM = 0.65;

  /// The frame the previews are drawn in.
  static const FrameSize frameSize = FrameSize(320, 240);

  /// Radius of the tracked object (block, ball, bob or cart), in metres.
  static const double objectRadiusM = 0.025;

  /// Frame pixels per metre for a frame of [frameSize].
  static double pxPerM(FrameSize frameSize) => frameSize.height / worldHeightM;

  /// World metres (y up) to frame pixels (y down).
  static Vec2 worldToFrame(Vec2 world, FrameSize frameSize) {
    final scale = pxPerM(frameSize);
    return Vec2(world.x * scale, frameSize.height - world.y * scale);
  }

  /// The apparatus for [mode] at time [t], so a preview can draw the ramp,
  /// floor, pendulum mount or second cart behind the overlay.
  static PreviewScenery scenery(ExperimentMode mode, double t) {
    const r = objectRadiusM;
    switch (mode) {
      case ExperimentMode.ramp:
        final down = Vec2(math.cos(_rampAngle), -math.sin(_rampAngle));
        final outward = Vec2(math.sin(_rampAngle), math.cos(_rampAngle));
        final surface = _rampStart - outward * r;
        final top = surface - down * 0.04;
        final bottom = surface + down * (_rampLength + 0.04);
        final corner = Vec2(top.x, bottom.y);
        return PreviewScenery(
          solids: [
            [top, bottom, corner],
          ],
          ground: [(Vec2(0, bottom.y), Vec2(bottom.x + 0.12, bottom.y))],
        );
      case ExperimentMode.freeFall:
        const floor = _fallFloor - r;
        return const PreviewScenery(
          ground: [(Vec2(0, floor), Vec2(0.86, floor))],
        );
      case ExperimentMode.pendulum:
        const pivot = _PendulumTable.pivot;
        return PreviewScenery(
          ceiling: [(pivot - const Vec2(0.12, 0), pivot + const Vec2(0.12, 0))],
          pivot: pivot,
        );
      case ExperimentMode.collision:
        const track = _cartY - r;
        return PreviewScenery(
          ground: const [(Vec2(0, track), Vec2(0.86, track))],
          boxes: [
            (
              center: Vec2(_collisionPartnerX(t), track + _partnerHalf),
              half: const Vec2(_partnerHalf, _partnerHalf),
            ),
          ],
        );
    }
  }

  static PhysicsState sample(
    ExperimentMode mode,
    double t, {
    FrameSize frameSize = PreviewPhysics.frameSize,
    double massKg = 0.1,
    int frameId = 0,
  }) {
    final m = massKg;
    final world = switch (mode) {
      ExperimentMode.ramp => _ramp(t, m),
      ExperimentMode.freeFall => _freeFall(t, m),
      ExperimentMode.pendulum => _pendulum(t, m),
      ExperimentMode.collision => _collision(t, m),
    };

    final pixel = worldToFrame(world.position, frameSize);
    final half = objectRadiusM * pxPerM(frameSize);

    return PhysicsState(
      frameId: frameId,
      t: t,
      tracked: true,
      pixel: pixel,
      bbox: PixelRect(pixel.x - half, pixel.y - half, half * 2, half * 2),
      position: world.position,
      velocity: world.velocity,
      acceleration: world.acceleration,
      forces: [...world.forces, ForceVector('net', world.acceleration * m)],
      energy: world.energy,
      extras: world.extras,
    );
  }

  static const _rampAngle = 25 * math.pi / 180;
  static const _rampLength = 0.62; // metres of travel before looping
  static const _rampStart = Vec2(0.08, 0.52);

  /// A block sliding down a 25° ramp with friction.
  static _World _ramp(double t, double m) {
    const theta = _rampAngle;
    const mu = 0.15;
    const length = _rampLength;
    const start = _rampStart;
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

  static const _fallFloor = 0.04;

  /// A ball launched up and to the right (projectile motion).
  static _World _freeFall(double t, double m) {
    const start = Vec2(0.06, 0.18);
    const v0 = Vec2(0.55, 2.4);
    const floor = _fallFloor;
    // Time to come back down to the floor.
    final tEnd =
        (v0.y + math.sqrt(v0.y * v0.y + 2 * g * (start.y - floor))) / g;
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
    final acceleration =
        tangent * (length * thetaDdot) +
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
      extras: {'theta_deg': theta * 180 / math.pi, 'length_m': length},
    );
  }

  static const _cartY = 0.06;
  static const _cartX0 = 0.06;
  static const _cartU = 0.9; // initial speed, m/s
  static const _cartDecel = 0.25; // rolling friction, m/s²
  static const _contactX = 0.5;
  static const _impact = 0.06; // seconds the carts are in contact
  static const _partnerHalf = 0.03; // the parked cart is a bit bigger

  /// Timing of one collision loop, shared by the cart and its partner.
  static ({double tHit, double vHit, double vAfter, double local})
  _collisionClock(double t) {
    const u = _cartU;
    const decel = _cartDecel;
    // Approach phase: x = x0 + u t - ½ d t², solved for the contact point.
    final tHit =
        (u - math.sqrt(u * u - 2 * decel * (_contactX - _cartX0))) / decel;
    final vHit = u - decel * tHit;
    final vAfter = -vHit / 3; // elastic, m against 2m
    final tStop = _impact + vAfter.abs() / decel;
    return (
      tHit: tHit,
      vHit: vHit,
      vAfter: vAfter,
      local: _loop(t, tHit + tStop, hold: 0.6),
    );
  }

  /// Centre of the parked cart. After the hit it leaves at two thirds of
  /// the first cart's speed and rolls to a stop.
  static double _collisionPartnerX(double t) {
    final (:tHit, :vHit, vAfter: _, :local) = _collisionClock(t);
    const rest = _contactX + objectRadiusM + _partnerHalf;
    if (local < tHit + _impact) return rest;
    final v2 = vHit * 2 / 3;
    final tt = math.min(local - tHit - _impact, v2 / _cartDecel);
    return rest + v2 * tt - 0.5 * _cartDecel * tt * tt;
  }

  /// A cart rolling into a parked cart twice its mass, elastically.
  /// We track the first cart, which bounces back at a third of its speed.
  static _World _collision(double t, double m) {
    const y = _cartY;
    const x0 = _cartX0;
    const u = _cartU;
    const decel = _cartDecel;
    const contactX = _contactX;
    const impact = _impact;
    final (:tHit, :vHit, :vAfter, :local) = _collisionClock(t);

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
      extras: {'momentum_x': m * v, 'momentum_y': 0},
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
    const k = PreviewPhysics.g / length;
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

/// Static apparatus for a preview, in world metres (y up).
class PreviewScenery {
  const PreviewScenery({
    this.ground = const [],
    this.ceiling = const [],
    this.solids = const [],
    this.pivot,
    this.boxes = const [],
  });

  /// Floors and tracks, with solid material below the line.
  final List<(Vec2, Vec2)> ground;

  /// Mounts, with solid material above the line.
  final List<(Vec2, Vec2)> ceiling;

  /// Filled shapes such as the ramp's wedge.
  final List<List<Vec2>> solids;

  /// Pendulum pivot; the string runs from here to the tracked bob.
  final Vec2? pivot;

  /// Other bodies, such as the parked cart in a collision.
  final List<({Vec2 center, Vec2 half})> boxes;
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
