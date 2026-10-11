import 'package:flutter/painting.dart' show Color;

import '../../../core/theme/tokens.dart';
import '../../../models/ar_vectors.dart';
import '../../../models/physics_state.dart';
import '../../../models/vec3.dart';
import 'arrow_scale.dart';
import 'vector_overlay_painter.dart';

/// Turns a backend reply into the arrows the native AR view draws.
///
/// Lengths come from [ArrowScale] at its reference size, with one screen
/// pixel there drawn as [metresPerPx] in the world: a 1 m/s velocity is a
/// 12 cm arrow and the object's weight is 9 cm. Forces share one scale, so
/// a free-body diagram still adds up, exactly as in the 2D overlay.
abstract final class ArVectorSceneBuilder {
  /// World length of one reference pixel. Tune on a device: bigger reads
  /// better from far away, smaller crowds a tabletop less.
  static const double metresPerPx = 0.001;

  /// Shaft radius per pixel of the 2D overlay's stroke width.
  static const double radiusPerWidthPx = 0.0008;

  /// About one backend reply at 15 fps, so arrows glide between replies.
  static const double easeSeconds = 0.1;

  /// Null when there is nothing to anchor: the object is lost, or the
  /// reply has no `position_3d` (no AR surface was picked).
  static ArVectorScene? build(
    PhysicsState? state, {
    required double massKg,
    OverlayLayers layers = const OverlayLayers(),
    bool reduceMotion = false,
    bool showLabels = true,
  }) {
    final origin = state?.position3d;
    if (state == null || !state.tracked || origin == null) return null;

    final scale = ArrowScale(unit: 1, weightN: massKg.clamp(1e-6, 1e6) * 9.81);
    final arrows = <ArArrow>[];

    void add(
      String id,
      Vec3 vector,
      double lengthPx,
      Color color,
      double widthPx,
      String symbol, {
      String subscript = '',
      bool dashed = false,
    }) {
      if (!scale.visible(lengthPx) || vector.length == 0) return;
      arrows.add(
        ArArrow(
          id: id,
          direction: vector.normalized,
          lengthM: lengthPx * metresPerPx,
          radiusM: widthPx * radiusPerWidthPx,
          argb: color.toARGB32(),
          symbol: symbol,
          subscript: subscript,
          dashed: dashed,
        ),
      );
    }

    if (layers.forces && state.forces3d.isNotEmpty) {
      final lengths = scale.forceLengths({
        for (final f in state.forces3d) f.name: f.vector.length,
      });
      for (final f in state.forces3d) {
        final style = ForceStyle.of(f.name);
        add(
          'force:${f.name}',
          f.vector,
          lengths[f.name]!,
          style.color,
          style.dashed ? 2.2 : 3,
          style.symbol,
          subscript: style.subscript,
          dashed: style.dashed,
        );
      }
    }

    final a = state.acceleration3d;
    if (layers.acceleration && a != null) {
      add(
        'acceleration',
        a,
        scale.accelerationLength(a.length),
        AppColors.acceleration,
        3.5,
        'a',
      );
    }

    final v = state.velocity3d;
    if (layers.velocity && v != null) {
      add(
        'velocity',
        v,
        scale.velocityLength(v.length),
        AppColors.velocity,
        3.5,
        'v',
      );
    }

    return ArVectorScene(
      origin: origin,
      arrows: arrows,
      haloArgb: AppColors.graphiteDeep.toARGB32(),
      easeSeconds: reduceMotion ? 0 : easeSeconds,
      showLabels: showLabels,
    );
  }
}
