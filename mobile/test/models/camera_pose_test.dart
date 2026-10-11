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
}
