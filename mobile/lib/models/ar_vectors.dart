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
class ArVectorScene {
  const ArVectorScene({
    required this.origin,
    required this.arrows,
    required this.haloArgb,
    this.easeSeconds = 0,
    this.showLabels = true,
    this.objectRadiusPx = 0,
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

  /// The object's radius in the frame, pixels; 0 when unknown. The native
  /// view hides the parts of the arrows the real object would cover.
  final double objectRadiusPx;

  /// The `setVectors` arguments on the `handson/arkit` channel.
  /// [occluderRadiusM] is [objectRadiusPx] in world metres at [origin];
  /// 0 draws the arrows over the object.
  Map<String, Object> toMap({double occluderRadiusM = 0}) => {
    'origin': origin.toList(),
    'ease_s': easeSeconds,
    'labels': showLabels,
    'halo': haloArgb,
    'occluder_radius': occluderRadiusM,
    'arrows': [for (final a in arrows) a.toMap()],
  };
}
