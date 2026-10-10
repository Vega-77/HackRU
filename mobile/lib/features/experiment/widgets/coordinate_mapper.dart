import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../models/physics_state.dart';
import '../../../models/session_config.dart';
import '../../../models/vec2.dart';

/// Converts between frame pixels (the JPEG the backend saw, y down) and
/// screen pixels (the widget the frame is shown in).
///
/// The camera preview fills its widget like [BoxFit.cover]: scaled up until
/// both sides are covered, centred, and the overflow cropped. Demo mode has
/// no camera and uses [BoxFit.contain] so the whole simulated scene shows.
/// Whichever fit the background uses, the overlay must use the same one,
/// or arrows drift away from the object.
class CoordinateMapper {
  factory CoordinateMapper({
    required FrameSize frameSize,
    required Size viewSize,
    BoxFit fit = BoxFit.cover,
  }) {
    assert(fit == BoxFit.cover || fit == BoxFit.contain);
    final scale = _scaleFor(frameSize, viewSize, fit);
    final offset = Offset(
      (viewSize.width - frameSize.width * scale) / 2,
      (viewSize.height - frameSize.height * scale) / 2,
    );
    return CoordinateMapper._(frameSize, viewSize, fit, scale, offset);
  }

  const CoordinateMapper._(
    this.frameSize,
    this.viewSize,
    this.fit,
    this.scale,
    this.offset,
  );

  final FrameSize frameSize;
  final Size viewSize;
  final BoxFit fit;

  /// Screen pixels per frame pixel.
  final double scale;

  /// Where the frame's top-left corner lands on screen. Negative when
  /// [BoxFit.cover] crops that side.
  final Offset offset;

  static double _scaleFor(FrameSize frame, Size view, BoxFit fit) {
    if (frame.width <= 0 || frame.height <= 0) return 1;
    final sx = view.width / frame.width;
    final sy = view.height / frame.height;
    return fit == BoxFit.cover ? math.max(sx, sy) : math.min(sx, sy);
  }

  /// The frame's rectangle in screen pixels (may extend past the view).
  Rect get frameRect =>
      offset & Size(frameSize.width * scale, frameSize.height * scale);

  Offset toScreen(Vec2 framePx) =>
      Offset(offset.dx + framePx.x * scale, offset.dy + framePx.y * scale);

  Vec2 toFrame(Offset screen) =>
      Vec2((screen.dx - offset.dx) / scale, (screen.dy - offset.dy) / scale);

  Rect rectToScreen(PixelRect r) => Rect.fromLTWH(
    offset.dx + r.x * scale,
    offset.dy + r.y * scale,
    r.w * scale,
    r.h * scale,
  );

  /// Clamps a frame-pixel point to the part of the frame that is visible.
  Vec2 clampToVisible(Vec2 framePx) {
    final topLeft = toFrame(Offset.zero);
    final bottomRight = toFrame(Offset(viewSize.width, viewSize.height));
    return Vec2(
      framePx.x.clamp(
        math.max(0.0, topLeft.x),
        math.min(frameSize.width.toDouble(), bottomRight.x),
      ),
      framePx.y.clamp(
        math.max(0.0, topLeft.y),
        math.min(frameSize.height.toDouble(), bottomRight.y),
      ),
    );
  }

  /// A world-space direction (y up) as a screen direction (y down).
  /// Arrow lengths are chosen by `ArrowScale`, not by this mapper.
  static Offset worldToScreenDirection(Vec2 world) => Offset(world.x, -world.y);
}
