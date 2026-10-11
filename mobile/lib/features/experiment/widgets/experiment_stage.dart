import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/experiment_mode.dart';
import '../../../state/experiment_settings.dart';
import '../../../state/session_controller.dart';
import 'vector_overlay.dart';
import 'vector_overlay_painter.dart';

/// The picture with the arrows on it: the camera feed with the
/// [VectorOverlay] on top.
///
/// In a collision, the other selected object gets its own marker and
/// velocity arrow. Both layers use the same [BoxFit], so frame pixels from the backend land
/// exactly on the object the user sees.
class ExperimentStage extends ConsumerWidget {
  const ExperimentStage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final settings = ref.watch(experimentSettingsProvider);

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
            layers: OverlayLayers(
              velocity: settings.showVelocity,
              acceleration: settings.showAcceleration,
              forces: settings.showForces,
            ),
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
