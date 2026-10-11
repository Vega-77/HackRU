import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/logging/debug_log.dart';
import '../../../models/physics_state.dart';
import '../../../services/camera/frame_source.dart';
import 'ar_vector_scene.dart';
import 'vector_overlay_painter.dart';

/// Sends each backend reply to the native AR view as 3D arrows. Draws
/// nothing itself: the arrows are SceneKit nodes in the camera preview.
///
/// The native view eases between replies and redraws from ARKit's live
/// pose every screen refresh, so no ticker is needed here.
class ArVectorLayer extends StatefulWidget {
  const ArVectorLayer({
    super.key,
    required this.display,
    required this.state,
    required this.massKg,
    this.layers = const OverlayLayers(),
  });

  final ArVectorDisplay display;
  final PhysicsState? state;
  final double massKg;
  final OverlayLayers layers;

  @override
  State<ArVectorLayer> createState() => _ArVectorLayerState();
}

class _ArVectorLayerState extends State<ArVectorLayer> {
  bool _reduceMotion = false;
  bool _sentOnce = false;
  bool _warnedNo3d = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery isn't readable in initState, so the first scene goes here.
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (!_sentOnce) _push();
  }

  @override
  void didUpdateWidget(ArVectorLayer old) {
    super.didUpdateWidget(old);
    if (!identical(widget.display, old.display)) {
      unawaited(old.display.showArVectors(null));
    }
    if (!identical(widget.state, old.state) ||
        widget.layers != old.layers ||
        widget.massKg != old.massKg ||
        !identical(widget.display, old.display)) {
      _push();
    }
  }

  void _push() {
    _sentOnce = true;
    final state = widget.state;
    if (state != null &&
        state.tracked &&
        state.position3d == null &&
        !_warnedNo3d) {
      _warnedNo3d = true;
      log.w(
        'Frame ${state.frameId} is tracked but has no position_3d, '
        'so there are no 3D arrows. Check that the backend got the ar_plane.',
      );
    }
    final scene = ArVectorSceneBuilder.build(
      state,
      massKg: widget.massKg,
      layers: widget.layers,
      reduceMotion: _reduceMotion,
    );
    unawaited(widget.display.showArVectors(scene));
  }

  @override
  void dispose() {
    unawaited(widget.display.showArVectors(null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
