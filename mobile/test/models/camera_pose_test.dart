import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/camera_pose.dart';
import 'package:hands_on_physics/models/vec3.dart';

void main() {
  // At (2, 1, 0), turned a quarter turn left so it looks down world -x.
  const pose = CameraPose(
    fx: 500,
    fy: 500,
    cx: 160,
    cy: 213,
    cameraToWorld: [0, 0, 1, 2, 0, 1, 0, 1, -1, 0, 0, 0, 0, 0, 0, 1],
  );

  test('reads the camera position from the pose', () {
    expect(pose.position, const Vec3(2, 1, 0));
  });

  test('depth runs along the view axis', () {
    expect(pose.depthOf(const Vec3(-1, 1, 0)), closeTo(3, 1e-12));
    // Off to one side, the same depth.
    expect(pose.depthOf(const Vec3(-1, 1.5, 0.4)), closeTo(3, 1e-12));
    expect(pose.depthOf(const Vec3(5, 1, 0)), closeTo(-3, 1e-12));
  });

  test('turns frame pixels into metres at a point', () {
    expect(pose.metresAcross(50, const Vec3(-1, 1, 0)), closeTo(0.3, 1e-12));
    expect(pose.metresAcross(50, const Vec3(5, 1, 0)), 0);
  });

  group('surface tilt', () {
    ArSurface facing(List<double> normal) =>
        ArSurface(point: const [0, 0, 0], normal: normal);

    test('a table is level and a wall is upright', () {
      expect(facing(const [0, 1, 0]).tiltDeg, closeTo(0, 1e-9));
      expect(facing(const [0, 1, 0]).isLevel, isTrue);
      expect(facing(const [0, 0, 1]).tiltDeg, closeTo(90, 1e-9));
    });

    test('a ramp gives its angle whichever way it faces', () {
      const deg = 15 * math.pi / 180;
      final ramp = facing([math.sin(deg), math.cos(deg), 0]);
      expect(ramp.tiltDeg, closeTo(15, 1e-9));
      expect(ramp.isLevel, isFalse);
      // Upside down and unnormalised, the same plane.
      expect(
        facing([-2 * math.sin(deg), -2 * math.cos(deg), 0]).tiltDeg,
        closeTo(15, 1e-9),
      );
    });

    test('a wobble of a degree still counts as level', () {
      const deg = 1 * math.pi / 180;
      expect(facing([0, math.cos(deg), math.sin(deg)]).isLevel, isTrue);
    });
  });
}
