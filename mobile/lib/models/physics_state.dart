import 'dart:convert';

import 'vec2.dart';

/// Everything the backend tells us about one video frame.
///
/// Mirrors the `state` message in `docs/protocol.md`. Physical vectors are in
/// world space (SI units, y up); [pixel] and [bbox] are in frame pixels
/// (y down).
class PhysicsState {
  const PhysicsState({
    required this.frameId,
    required this.t,
    required this.tracked,
    this.pixel,
    this.bbox,
    this.position,
    this.velocity,
    this.acceleration,
    this.forces = const [],
    this.energy,
    this.extras = const {},
    this.screenAxes,
    this.trackingDebug = const {},
    this.trackingStatus,
  });

  /// Echo of the `frame_id` the client sent with the frame.
  final int frameId;

  /// Echo of the frame's capture `timestamp`, in seconds.
  final double t;

  /// False when the backend could not find the object in this frame.
  final bool tracked;

  final Vec2? pixel;
  final PixelRect? bbox;
  final Vec2? position;
  final Vec2? velocity;
  final Vec2? acceleration;
  final List<ForceVector> forces;
  final EnergyState? energy;

  /// Mode-specific readouts such as `angle_deg` or `mu`.
  final Map<String, double> extras;

  /// How world +x and +y look on screen at the object. Null without a
  /// metric calibration.
  final ScreenAxes? screenAxes;
  final Map<String, dynamic> trackingDebug;
  final String? trackingStatus;

  factory PhysicsState.fromJson(Map<String, dynamic> json) {
    final rawForces = json['forces'];
    final rawExtras = json['extras'];
    return PhysicsState(
      frameId: (json['frame_id'] as num?)?.toInt() ?? -1,
      t: (json['timestamp'] as num?)?.toDouble() ?? 0,
      tracked: json['tracked'] == true,
      trackingStatus: json['tracking_status'] as String?,
      pixel: Vec2.tryParse(json['pixel']),
      bbox: PixelRect.tryParse(json['bbox']),
      position: Vec2.tryParse(json['position']),
      velocity: Vec2.tryParse(json['velocity']),
      acceleration: Vec2.tryParse(json['acceleration']),
      forces: rawForces is List
          ? rawForces
                .map(ForceVector.tryParse)
                .whereType<ForceVector>()
                .toList()
          : const [],
      energy: EnergyState.tryParse(json['energy']),
      extras: rawExtras is Map
          ? {
              for (final e in rawExtras.entries)
                if (e.value is num) '${e.key}': (e.value as num).toDouble(),
            }
          : const {},
      screenAxes: ScreenAxes.tryParse(json['screen_axes']),
      trackingDebug: json['tracking_debug'] is Map<String, dynamic>
          ? json['tracking_debug'] as Map<String, dynamic>
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'type': 'state',
    'frame_id': frameId,
    'timestamp': t,
    'tracked': tracked,
    if (pixel != null) 'pixel': pixel!.toJson(),
    if (bbox != null) 'bbox': bbox!.toJson(),
    if (position != null) 'position': position!.toJson(),
    if (velocity != null) 'velocity': velocity!.toJson(),
    if (acceleration != null) 'acceleration': acceleration!.toJson(),
    'forces': [for (final f in forces) f.toJson()],
    if (energy != null) 'energy': energy!.toJson(),
    'extras': extras,
    if (screenAxes != null) 'screen_axes': screenAxes!.toJson(),
  };
}

/// Where world +x and +y point in the camera image at the object, in frame
/// pixels per metre (y down). With a tilted surface or an AR pose these are
/// not simply right and up, so arrows follow them to lie on the surface.
class ScreenAxes {
  const ScreenAxes(this.x, this.y);

  final Vec2 x;
  final Vec2 y;

  /// A world vector's direction in frame pixels, not normalised.
  Vec2 project(Vec2 world) => x * world.x + y * world.y;

  static ScreenAxes? tryParse(Object? json) {
    if (json is! Map) return null;
    final x = Vec2.tryParse(json['x']);
    final y = Vec2.tryParse(json['y']);
    return x == null || y == null ? null : ScreenAxes(x, y);
  }

  Map<String, dynamic> toJson() => {'x': x.toJson(), 'y': y.toJson()};
}

/// How a force is drawn: the net force in blue, its components in yellow.
enum ForceKind { net, component }

class ForceVector {
  const ForceVector(this.name, this.vector);

  /// One of `gravity`, `normal`, `friction`, `tension`, `gravity_parallel`,
  /// `gravity_perpendicular`, `net`, or a name we don't know yet.
  final String name;

  /// Newtons, world space.
  final Vec2 vector;

  ForceKind get kind => name == 'net' ? ForceKind.net : ForceKind.component;

  static ForceVector? tryParse(Object? json) {
    if (json is! Map || json['name'] is! String) return null;
    final vector = Vec2.tryParse(json);
    return vector == null ? null : ForceVector(json['name'] as String, vector);
  }

  Map<String, dynamic> toJson() => {'name': name, ...vector.toJson()};
}

/// Energy audit values in joules. Any of them may be missing.
class EnergyState {
  const EnergyState({this.kinetic, this.potential, this.thermal});

  final double? kinetic;
  final double? potential;
  final double? thermal;

  double get total => (kinetic ?? 0) + (potential ?? 0) + (thermal ?? 0);

  static EnergyState? tryParse(Object? json) {
    if (json is! Map) return null;
    double? read(String key) => (json[key] as num?)?.toDouble();
    return EnergyState(
      kinetic: read('kinetic'),
      potential: read('potential'),
      thermal: read('thermal'),
    );
  }

  Map<String, double> toJson() => {
    'kinetic': ?kinetic,
    'potential': ?potential,
    'thermal': ?thermal,
  };
}

/// An axis-aligned rectangle in frame pixels.
class PixelRect {
  const PixelRect(this.x, this.y, this.w, this.h);

  final double x;
  final double y;
  final double w;
  final double h;

  static PixelRect? tryParse(Object? json) {
    if (json is! Map) return null;
    final values = [json['x'], json['y'], json['w'], json['h']];
    if (values.any((v) => v is! num)) return null;
    final [x, y, w, h] = values.cast<num>().map((v) => v.toDouble()).toList();
    return PixelRect(x, y, w, h);
  }

  Map<String, double> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}

/// Any message the server can send, parsed from raw WebSocket text.
sealed class ServerMessage {
  const ServerMessage();

  /// The `frame_id` this message answers, or null if it isn't a reply to
  /// a frame. The socket uses it for flow control and latency.
  int? get frameId => null;

  /// Never throws: malformed input becomes an [UnknownMessage].
  static ServerMessage parse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return UnknownMessage(raw);
      return switch (json['type']) {
        'state' => StateMessage(PhysicsState.fromJson(json)),
        'frame' => FrameAckMessage.fromJson(json),
        'error' => ErrorMessage.fromJson(json),
        'initialization' => InitializationMessage(
          (json['frame_id'] as num?)?.toInt() ?? -1,
          '${json['status']}',
          '${json['reason']}',
        ),
        _ => UnknownMessage(raw),
      };
    } on FormatException {
      return UnknownMessage(raw);
    }
  }
}

class InitializationMessage extends ServerMessage {
  const InitializationMessage(this.frameId, this.status, this.reason);
  @override
  final int frameId;
  final String status;
  final String reason;
}

class StateMessage extends ServerMessage {
  const StateMessage(this.state);
  final PhysicsState state;

  @override
  int get frameId => state.frameId;
}

/// The CV engine's per-frame report (`type: frame`). Until the physics
/// stage sends `state`, it is the only sign of where the object is.
class FrameAckMessage extends ServerMessage {
  const FrameAckMessage({
    required this.frameId,
    this.processMs,
    this.objects = const [],
    this.target,
  });

  @override
  final int frameId;

  /// Time the backend spent on this frame.
  final double? processMs;

  /// Every detection, as sent. See docs/protocol.md for the fields.
  final List<Map<String, dynamic>> objects;

  /// The object the backend is following (`"target": true`), as a state
  /// with only its place filled in: no velocity, acceleration or forces.
  /// Null when nothing is marked as the target.
  final PhysicsState? target;

  factory FrameAckMessage.fromJson(Map<String, dynamic> json) {
    final frameId = (json['frame_id'] as num?)?.toInt() ?? -1;
    final rawObjects = json['objects'];
    final objects = rawObjects is List
        ? rawObjects.whereType<Map<String, dynamic>>().toList()
        : const <Map<String, dynamic>>[];
    final followed = objects.where((o) => o['target'] == true).firstOrNull;
    final pixel = followed == null ? null : Vec2.tryParse(followed['pixel']);

    return FrameAckMessage(
      frameId: frameId,
      processMs: (json['process_ms'] as num?)?.toDouble(),
      objects: objects,
      target: pixel == null
          ? null
          : PhysicsState(
              frameId: frameId,
              t: (json['timestamp'] as num?)?.toDouble() ?? 0,
              tracked: json['tracked'] != false,
              pixel: pixel,
              bbox: PixelRect.tryParse(followed!['bbox']),
              position: Vec2.tryParse(followed['position']),
              screenAxes: ScreenAxes.tryParse(followed['screen_axes']),
            ),
    );
  }
}

class ErrorMessage extends ServerMessage {
  const ErrorMessage(
    this.message, {
    this.frameId,
    this.where,
    this.serverVersion,
  });

  /// The `error` object only comes with a frame that crashed the backend.
  factory ErrorMessage.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    final details = error is Map<String, dynamic> ? error : const {};
    return ErrorMessage(
      '${json['message'] ?? 'Unknown server error'}',
      frameId: (json['frame_id'] as num?)?.toInt(),
      where: details['where'] as String?,
      serverVersion: details['server'] as String?,
    );
  }

  final String message;

  /// Set when the error is about one frame (for example, it failed to decode).
  @override
  final int? frameId;

  /// The backend code that crashed, like `backend/cv_engine/universal.py:69
  /// in detect`.
  final String? where;

  /// The deployed backend commit, so you can tell whether a fix is live.
  final String? serverVersion;
}

class UnknownMessage extends ServerMessage {
  const UnknownMessage(this.raw);
  final String raw;
}
