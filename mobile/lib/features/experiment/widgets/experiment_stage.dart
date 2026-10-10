import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/experiment_settings.dart';
import '../../../state/session_controller.dart';
import 'demo_scene.dart';
import 'vector_overlay.dart';
import 'vector_overlay_painter.dart';

/// The picture with the arrows on it: the camera feed in live mode, or the
/// drawn demo scene, with the [VectorOverlay] on top.
///
/// Both layers use the same [BoxFit], so frame pixels from the backend land
/// exactly on the object the user sees.
class ExperimentStage extends ConsumerWidget {
  const ExperimentStage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final settings = ref.watch(experimentSettingsProvider);
    final frameSize = session.frameSize ?? SessionController.demoFrameSize;
    final demo = settings.demoMode;
    final fit = demo ? DemoScene.fit : BoxFit.cover;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (demo)
            DemoScene(
              mode: settings.mode,
              frameSize: frameSize,
              t: session.latest?.t ?? 0,
            )
          else if (session.phase == SessionPhase.running ||
              session.phase == SessionPhase.paused)
            ref.read(frameSourceProvider).buildPreview(context)
          else
            const ColoredBox(color: Colors.black),
          VectorOverlay(
            state: session.latest,
            frameSize: frameSize,
            massKg: settings.massKg,
            fit: fit,
            layers: OverlayLayers(
              velocity: settings.showVelocity,
              acceleration: settings.showAcceleration,
              forces: settings.showForces,
            ),
            tether: demo ? DemoScene.tetherFor(settings.mode, frameSize) : null,
          ),
        ],
      ),
    );
  }
}
