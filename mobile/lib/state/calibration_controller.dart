import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../models/calibration.dart';
import '../models/camera_pose.dart';
import '../models/vec2.dart';

/// Holds the ruler endpoints and tracking target, all in frame pixels, and
/// the AR surface when the user picked one.
class CalibrationController extends Notifier<Calibration> {
  @override
  Calibration build() =>
      const Calibration(rulerLengthM: AppConfig.defaultRulerLengthM);

  void setRulerStart(Vec2 p) => state = state.copyWith(rulerStart: p);

  void setRulerEnd(Vec2 p) => state = state.copyWith(rulerEnd: p);

  void setRulerLength(double metres) =>
      state = state.copyWith(rulerLengthM: metres.clamp(0.01, 5.0));

  void setTarget(Vec2 p) => state = state.copyWith(target: p);

  void clearTarget() => state = state.clearTarget();

  void setSurface(ArSurface surface) =>
      state = state.copyWith(surface: surface);

  void clearSurface() => state = state.clearSurface();

  void reset() => state = build();
}

final calibrationProvider =
    NotifierProvider<CalibrationController, Calibration>(
      CalibrationController.new,
    );
