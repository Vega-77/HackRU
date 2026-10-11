import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/calibration/surface_copy.dart';
import 'package:hands_on_physics/models/camera_pose.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';

void main() {
  const floor = ArSurface(point: [0, 0, 0], normal: [0, 1, 0]);
  const board = ArSurface(point: [0, 0, -1], normal: [0, 0, 1], vertical: true);
  const deg = 12 * math.pi / 180;
  final ramp = ArSurface(
    point: const [0, 0, 0],
    normal: [0, math.cos(deg), math.sin(deg)],
  );

  test('on a ramp, asks for the ramp itself', () {
    expect(
      SurfaceCopy.instructions(ExperimentMode.ramp),
      contains('the ramp itself'),
    );
  });

  test('gives the ramp angle when the ramp is found', () {
    expect(
      SurfaceCopy.status(ExperimentMode.ramp, ramp),
      'Using the ramp, tilted 12°',
    );
  });

  test('says the floor under a ramp is level', () {
    expect(
      SurfaceCopy.status(ExperimentMode.ramp, floor),
      startsWith('This surface is level.'),
    );
  });

  test('a board behind any experiment is a vertical board', () {
    for (final mode in ExperimentMode.values) {
      expect(SurfaceCopy.status(mode, board), 'Using a vertical board');
    }
  });

  test('a miss beats a surface found earlier', () {
    expect(
      SurfaceCopy.status(ExperimentMode.ramp, ramp, missed: true),
      startsWith('No surface found there.'),
    );
    expect(SurfaceCopy.status(ExperimentMode.ramp, null), 'No surface yet');
  });

  test('carts roll on a table top', () {
    expect(
      SurfaceCopy.status(ExperimentMode.collision, floor),
      'Using a table top',
    );
  });
}
