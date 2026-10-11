import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/experiment_mode.dart';
import '../../../services/camera/frame_source.dart';
import '../../../state/calibration_controller.dart';
import '../../../state/experiment_settings.dart';
import '../../../state/session_controller.dart';
import 'ar_vector_layer.dart';
import 'vector_overlay.dart';
import 'vector_overlay_painter.dart';

/// The picture with the arrows on it: the camera feed with the
/// [VectorOverlay] on top.
///
/// In a collision, the other selected object gets its own marker and
/// velocity arrow. Both layers use the same [BoxFit], so frame pixels from the backend land
/// exactly on the object the user sees.
///
/// With ARKit and a picked surface, the arrows are drawn in 3D by the
/// camera preview instead ([ArVectorLayer]), anchored in the world so they
/// stay on the object while the phone moves. The 2D overlay then only
/// draws the marker and trail.
class ExperimentStage extends ConsumerWidget {
  const ExperimentStage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final settings = ref.watch(experimentSettingsProvider);
    final hasSurface = ref.watch(
      calibrationProvider.select((c) => c.surface != null),
    );
    final layers = OverlayLayers(
      velocity: settings.showVelocity,
      acceleration: settings.showAcceleration,
      forces: settings.showForces,
    );
    final arDisplay = switch (ref.read(frameSourceProvider)) {
      final ArVectorDisplay d
          when session.isActive && hasSurface && d.canShowArVectors =>
        d,
      _ => null,
    };

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (session.isActive)
            ref.read(frameSourceProvider).buildPreview(context)
          else
            const ColoredBox(color: Colors.black),
          VectorOverlay(
            state: session.latest,
            frameSize: session.frameSize ?? SessionController.fallbackFrameSize,
            massKg: settings.massKg,
            // The camera preview always fills its box this way.
            fit: BoxFit.cover,
            layers: arDisplay == null ? layers : OverlayLayers.none,
            // On the ball between replies, with the 3D arrows.
            liveBox: arDisplay?.followedBox,
          ),
          if (arDisplay != null)
            ArVectorLayer(
              display: arDisplay,
              state: session.latest,
              massKg: settings.massKg,
              layers: layers,
            ),
          if (settings.mode == ExperimentMode.collision)
            VectorOverlay(
              state: session.latest?.partner,
              frameSize:
                  session.frameSize ?? SessionController.fallbackFrameSize,
              massKg: settings.massKg,
              fit: BoxFit.cover,
              layers: OverlayLayers(
                velocity: settings.showVelocity,
                acceleration: false,
                forces: false,
              ),
            ),
        ],
      ),
    );
  }
}
