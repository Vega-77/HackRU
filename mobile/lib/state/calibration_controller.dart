import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/logging/debug_log.dart';
import '../models/calibration.dart';
import '../models/camera_pose.dart';
import '../models/physics_state.dart';
import '../models/session_config.dart';
import '../models/vec2.dart';

/// Holds the ruler endpoints and tracking target, all in frame pixels, and
/// the AR surface when the user picked one.
///
/// Ruler drags log at debug level, since they fire on every drag update.
class CalibrationController extends Notifier<Calibration> {
  @override
  Calibration build() =>
      const Calibration(rulerLengthM: AppConfig.defaultRulerLengthM);

  void setRulerStart(Vec2 p) {
    state = state.copyWith(rulerStart: p);
    log.d('Ruler start $p, ${_scale()}');
  }

  void setRulerEnd(Vec2 p) {
    state = state.copyWith(rulerEnd: p);
    log.d('Ruler end $p, ${_scale()}');
  }

  void setRulerLength(double metres) {
    state = state.copyWith(rulerLengthM: metres.clamp(0.01, 5.0));
    log.i('Ruler length ${state.rulerLengthM} m, ${_scale()}');
  }

  void setTarget(Vec2 p) {
    state = state.clearTarget().copyWith(target: p);
    log.i('Target tapped at $p');
  }

  void selectObject(Vec2 point, PixelRect? box, EncodedFrame frame) {
    state = state.clearTarget().copyWith(
      target: point,
      targetBbox: box,
      selectionFrame: frame,
    );
    log.i('Object selected at $point in captured frame ${frame.captureTime}');
  }

  void clearTarget() {
    state = state.clearTarget();
    log.i('Target cleared');
  }

  void setSurface(ArSurface surface) {
    state = state.copyWith(surface: surface);
    log.i('Surface set: ${surface.vertical ? 'vertical' : 'horizontal'}');
  }

  void clearSurface() {
    state = state.clearSurface();
    log.i('Surface cleared');
  }

  void reset() {
    state = build();
    log.i('Calibration reset');
  }

  String _scale() => '${state.pxPerM?.toStringAsFixed(1) ?? 'no'} px/m';
}

final calibrationProvider =
    NotifierProvider<CalibrationController, Calibration>(
      CalibrationController.new,
    );
