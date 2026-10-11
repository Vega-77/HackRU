import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/logging/debug_log.dart';
import '../models/calibration.dart';
import '../models/camera_pose.dart';
import '../models/experiment_mode.dart';
import '../models/physics_state.dart';
import '../models/session_config.dart';
import '../models/vec2.dart';
import 'experiment_settings.dart';

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

  /// Whether a new selection marks the second object of a collision: the
  /// first is confirmed and the second is not yet.
  bool get choosingSecond =>
      ref.read(experimentSettingsProvider).mode == ExperimentMode.collision &&
      state.selectionConfirmed &&
      !(state.second?.confirmed ?? false);

  void selectObject(Vec2 point, PixelRect? box, EncodedFrame frame) {
    if (choosingSecond) {
      state = state.withSecond(
        ObjectSelection(point: point, frame: frame, box: box),
      );
      log.i(
        'Second object selected at $point, box ${box?.toJson()}, in captured frame ${frame.captureTime}',
      );
      return;
    }
    state = state.clearTarget().copyWith(
      target: point,
      targetBbox: box,
      selectionFrame: frame,
    );
    log.i(
      'Object selected at $point, box ${box?.toJson()}, in captured frame ${frame.captureTime}',
    );
  }

  void beginAcquisition(Vec2 point, EncodedFrame frame) {
    if (choosingSecond) {
      selectObject(point, null, frame);
      state = state.withSecond(state.second!.copyWith(pending: true));
      return;
    }
    selectObject(point, null, frame);
    state = state.copyWith(selectionPending: true);
  }

  void acquisitionFailed(String message) {
    if (choosingSecond) {
      state = state.withSecond(
        state.second?.copyWith(pending: false),
        error: message,
      );
    } else {
      state = state.copyWith(selectionPending: false, selectionError: message);
    }
    log.w(message);
  }

  void confirmSelection() {
    final second = state.second;
    if (choosingSecond) {
      if (second != null && second.box != null && !second.pending) {
        state = state.withSecond(second.copyWith(confirmed: true));
        log.i('Second object region confirmed: ${second.box!.toJson()}');
      }
      return;
    }
    if (state.targetBbox != null && !state.selectionPending) {
      state = state.copyWith(selectionConfirmed: true);
      log.i('Object region confirmed: ${state.targetBbox!.toJson()}');
    }
  }

  void clearTarget() {
    state = state.clearTarget();
    log.i('Target cleared');
  }

  void clearSecond() {
    state = state.withSecond(null);
    log.i('Second object cleared');
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
