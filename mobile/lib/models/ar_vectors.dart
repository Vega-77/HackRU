import 'dart:math' as math;

import 'physics_state.dart';
import 'session_config.dart';
import 'vec3.dart';

/// One arrow to draw in the AR scene, in ARKit world space.
class ArArrow {
  const ArArrow({
    required this.id,
    required this.direction,
    required this.lengthM,
    required this.radiusM,
    required this.argb,
    required this.symbol,
    this.subscript = '',
    this.dashed = false,
  });

  /// Stable across updates (`velocity`, `acceleration`, `force:normal`),
  /// so the native side moves the same node instead of making a new one.
  final String id;

  /// Unit vector the arrow points along.
  final Vec3 direction;

  /// Tip distance from the object's centre, metres.
  final double lengthM;

  /// Shaft radius, metres. The head is wider.
  final double radiusM;

  /// Colour as 0xAARRGGBB, from the physics palette.
  final int argb;

  /// Label drawn past the tip, like `F` with subscript `N`.
  final String symbol;
  final String subscript;

  /// Components of another force are dashed, as in the 2D overlay.
  final bool dashed;

  Map<String, Object> toMap() => {
    'id': id,
    'direction': direction.toList(),
    'length': lengthM,
    'radius': radiusM,
    'color': argb,
    'symbol': symbol,
    'subscript': subscript,
    'dashed': dashed,
  };
}

/// Everything the native AR view draws for one backend reply: arrows
/// rooted at the tracked object's centre.
///
/// The native view keeps drawing it at the screen's refresh rate from
/// ARKit's live camera pose, so arrows stay put on the object while the
/// phone moves, between the backend's replies.
///
/// With a [box], the native view also tracks the object on every camera
/// frame (ArObjectFollower.swift), starting from [box] on the frame taken
/// at [capturedAt], and roots the arrows where it is on screen right now
/// instead of where the backend saw it a few frames ago.
class ArVectorScene {
  const ArVectorScene({
    required this.origin,
    required this.arrows,
    required this.haloArgb,
    this.easeSeconds = 0,
    this.showLabels = true,
    this.box,
    this.capturedAt,
    this.boxRadiusFactor = 1,
  });

  /// The object's centre, ARKit world metres.
  final Vec3 origin;
  final List<ArArrow> arrows;

  /// Outline drawn around every arrow and label so they read on any
  /// background, as in the 2D overlay.
  final int haloArgb;

  /// How long the native side takes to move arrows to this scene. About
  /// one reply interval, so they glide instead of jumping; 0 when the
  /// system asks for reduced motion.
  final double easeSeconds;
  final bool showLabels;

  /// The object's bounding box in the frame the backend measured, pixels.
  final PixelRect? box;

  /// When that frame was taken, the camera's own clock (the reply's
  /// echoed timestamp).
  final double? capturedAt;

  /// The share of the box's smaller half-side taken as the object's radius.
  final double boxRadiusFactor;

  /// The object's radius in the frame, pixels; 0 when unknown. The native
  /// view hides the parts of the arrows the real object would cover.
  double get objectRadiusPx {
    final box = this.box;
    return box == null ? 0 : math.min(box.w, box.h) / 2 * boxRadiusFactor;
  }

  /// The `setVectors` arguments on the `handson/arkit` channel.
  /// [occluderRadiusM] is [objectRadiusPx] in world metres at [origin];
  /// 0 draws the arrows over the object. [frameSize] normalizes [box] for
  /// on-device tracking, which is left off without it.
  Map<String, Object> toMap({
    double occluderRadiusM = 0,
    FrameSize? frameSize,
  }) {
    final box = this.box;
    final capturedAt = this.capturedAt;
    return {
      'origin': origin.toList(),
      'ease_s': easeSeconds,
      'labels': showLabels,
      'halo': haloArgb,
      'occluder_radius': occluderRadiusM,
      'arrows': [for (final a in arrows) a.toMap()],
      if (box != null && capturedAt != null && frameSize != null) ...{
        'box': [
          box.x / frameSize.width,
          box.y / frameSize.height,
          box.w / frameSize.width,
          box.h / frameSize.height,
        ],
        'captured_at': capturedAt,
        'box_radius_factor': boxRadiusFactor,
      },
    };
  }
}
