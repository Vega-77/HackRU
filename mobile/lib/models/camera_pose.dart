import 'dart:math' as math;

import 'vec3.dart';

/// The camera that took one frame, from ARKit on iOS. Lets the backend turn
/// a pixel into a 3D ray (docs/protocol.md, "ARKit pose").
class CameraPose {
  const CameraPose({
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.cameraToWorld,
  });

  factory CameraPose.fromMap(Map<Object?, Object?> map) {
    double n(Object? v) => (v! as num).toDouble();
    final intrinsics = map['intrinsics']! as List<Object?>;
    return CameraPose(
      fx: n(intrinsics[0]),
      fy: n(intrinsics[1]),
      cx: n(intrinsics[2]),
      cy: n(intrinsics[3]),
      cameraToWorld: [
        for (final v in map['camera_to_world']! as List<Object?>) n(v),
      ],
    );
  }

  /// Focal lengths and principal point, in the pixels of the frame sent.
  final double fx, fy, cx, cy;

  /// 4x4 as 16 numbers, row-major. Camera axes are x right, y up, z towards the viewer;
  /// world axes are ARKit's, in metres with +y up against gravity.
  final List<double> cameraToWorld;

  /// Where the camera was, ARKit world metres.
  Vec3 get position =>
      Vec3(cameraToWorld[3], cameraToWorld[7], cameraToWorld[11]);

  /// How far in front of the camera [point] is, along its view axis.
  /// Negative behind it.
  double depthOf(Vec3 point) {
    final m = cameraToWorld;
    final d = point - position;
    // The camera looks down its own -z axis, the rotation's third column.
    return -(d.x * m[2] + d.y * m[6] + d.z * m[10]);
  }

  /// World metres that [px] frame pixels span at [point], across the view.
  /// 0 when the point is behind the camera.
  double metresAcross(double px, Vec3 point) {
    final depth = depthOf(point);
    return depth > 0 && fx > 0 ? px * depth / fx : 0;
  }

  Map<String, dynamic> toJson() => {
    'intrinsics': {'fx': fx, 'fy': fy, 'cx': cx, 'cy': cy},
    'camera_to_world': cameraToWorld,
  };
}

/// A real surface ARKit found where the user pointed: the board or table
/// the object moves on. ARKit world coordinates, metres.
class ArSurface {
  const ArSurface({
    required this.point,
    required this.normal,
    this.vertical = false,
    this.offsetM = 0,
    this.id,
  });

  factory ArSurface.fromMap(Map<Object?, Object?> map) {
    List<double> v(Object? list) => [
      for (final x in list! as List<Object?>) (x! as num).toDouble(),
    ];
    return ArSurface(
      point: v(map['point']),
      normal: v(map['normal']),
      vertical: map['vertical'] == true,
      id: map['id'] as String?,
    );
  }

  /// ARKit's anchor ID, for planes from `surfaces`. Null for a raycast hit.
  final String? id;

  final List<double> point;
  final List<double> normal;

  /// A wall or board, as opposed to a table top.
  final bool vertical;

  /// How far in front of the surface the object's centre is, such as a
  /// ball's radius. Keeps positions at the centre, not the contact point.
  final double offsetM;

  /// Below this tilt a surface counts as level: a floor or table, not a
  /// ramp. ARKit's estimated planes wobble by a degree or two.
  static const double levelTiltDeg = 3;

  /// Degrees between the surface and level ground: 0 for a table, 90 for
  /// a wall.
  double get tiltDeg {
    final n = Vec3(normal[0], normal[1], normal[2]);
    if (n.length == 0) return 0;
    return math.acos((n.y.abs() / n.length).clamp(0.0, 1.0)) * 180 / math.pi;
  }

  bool get isLevel => tiltDeg < levelTiltDeg;

  ArSurface withOffset(double metres) => ArSurface(
    point: point,
    normal: normal,
    vertical: vertical,
    offsetM: metres,
    id: id,
  );

  Map<String, dynamic> toJson() => {
    'point': point,
    'normal': normal,
    'offset_m': offsetM,
  };

  /// As one of the config's `ar_surfaces`: a plane the object may rest on.
  Map<String, dynamic> toSurfaceJson() => {
    'id': ?id,
    'point': point,
    'normal': normal,
  };
}
