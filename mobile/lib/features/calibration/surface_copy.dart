import '../../models/camera_pose.dart';
import '../../models/experiment_mode.dart';

/// What the surface step asks for and says about the surface it found.
///
/// On a ramp, the ramp itself is the best surface: the backend reads the
/// ramp's angle from its tilt and draws the normal force across it. A
/// board standing behind the experiment also works. A level surface, such
/// as the floor under the ramp, gives no angle, so the step says so.
abstract final class SurfaceCopy {
  static String instructions(ExperimentMode mode) => switch (mode) {
    ExperimentMode.collision =>
      'Aim the middle of the picture at the table the carts roll on, '
          'then tap Find.',
    ExperimentMode.ramp =>
      'Aim the middle of the picture at the ramp itself, or at a board '
          'standing behind it, then tap Find.',
    _ =>
      'Aim the middle of the picture at a board behind the experiment, '
          'parallel to the motion, then tap Find.',
  };

  static String status(
    ExperimentMode mode,
    ArSurface? surface, {
    bool missed = false,
  }) {
    if (missed) {
      return 'No surface found there. Move the phone slowly so it can map '
          'the scene, then try again.';
    }
    if (surface == null) return 'No surface yet';
    if (surface.vertical) return 'Using a vertical board';
    if (mode == ExperimentMode.ramp) {
      if (surface.isLevel) {
        return 'This surface is level. Aim at the ramp itself and tap Find '
            'again to measure its angle.';
      }
      return 'Using the ramp, tilted ${surface.tiltDeg.round()}°';
    }
    if (mode == ExperimentMode.collision) return 'Using a table top';
    // Gravity lies in a vertical board, so its 2D physics is exact there.
    return 'Using a table top. For this experiment, the board behind it '
        'gives better forces.';
  }
}
