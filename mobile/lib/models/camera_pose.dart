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
  });

  factory ArSurface.fromMap(Map<Object?, Object?> map) {
    List<double> v(Object? list) => [
      for (final x in list! as List<Object?>) (x! as num).toDouble(),
    ];
    return ArSurface(
      point: v(map['point']),
      normal: v(map['normal']),
      vertical: map['vertical'] == true,
    );
  }

  final List<double> point;
  final List<double> normal;

  /// A wall or board, as opposed to a table top.
  final bool vertical;

  /// How far in front of the surface the object's centre is, such as a
  /// ball's radius. Keeps positions at the centre, not the contact point.
  final double offsetM;

  ArSurface withOffset(double metres) => ArSurface(
    point: point,
    normal: normal,
    vertical: vertical,
    offsetM: metres,
  );

  Map<String, dynamic> toJson() => {
    'point': point,
    'normal': normal,
    'offset_m': offsetM,
  };
}
