import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../models/experiment_mode.dart';
import '../../../models/physics_state.dart';
import '../../experiment/widgets/vector_overlay.dart';
import 'preview_physics.dart';
import 'preview_scene.dart';

/// A small, self-running version of the experiment screen: a drawn scene
/// with the real vector overlay on top, fed by [PreviewPhysics].
///
/// It is the actual component, not an illustration of it, so what you see
/// on the home screen is what the experiment screen will draw.
///
/// With [animate] off (or when the system asks for reduced motion) it shows
/// one representative moment of the experiment instead.
class ExperimentPreview extends StatefulWidget {
  const ExperimentPreview({
    super.key,
    required this.mode,
    this.animate = true,
    this.showLabels = true,
    this.showGrid = true,
  });

  final ExperimentMode mode;
  final bool animate;
  final bool showLabels;
  final bool showGrid;

  /// A moment in each loop that shows every arrow clearly.
  static double stillTime(ExperimentMode mode) => switch (mode) {
    ExperimentMode.ramp => 0.42,
    ExperimentMode.freeFall => 0.3,
    ExperimentMode.pendulum => 0.18,
    ExperimentMode.collision => 0.3,
  };

  @override
  State<ExperimentPreview> createState() => _ExperimentPreviewState();
}

class _ExperimentPreviewState extends State<ExperimentPreview>
    with SingleTickerProviderStateMixin {
  static const _frameSize = PreviewPhysics.frameSize;

  /// Same rate as the real data, so the overlay's smoothing looks the same.
  static const _step = Duration(milliseconds: 66);

  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastStep = Duration.zero;
  late PhysicsState _state = _sample(ExperimentPreview.stillTime(widget.mode));

  bool get _running =>
      widget.animate && !MediaQuery.disableAnimationsOf(context);

  PhysicsState _sample(double t) =>
      PreviewPhysics.sample(widget.mode, t, frameSize: _frameSize);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ExperimentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _state = _sample(ExperimentPreview.stillTime(widget.mode));
      if (_ticker.isActive) _ticker.stop();
    }
    _syncTicker();
  }

  void _syncTicker() {
    if (_running && !_ticker.isActive) {
      _lastStep = Duration.zero;
      _ticker.start();
    } else if (!_running && _ticker.isActive) {
      _ticker.stop();
      setState(
        () => _state = _sample(ExperimentPreview.stillTime(widget.mode)),
      );
    }
  }

  void _onTick(Duration elapsed) {
    if (elapsed - _lastStep < _step) return;
    _lastStep = elapsed;
    setState(() => _state = _sample(elapsed.inMicroseconds / 1e6));
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPendulum = widget.mode == ExperimentMode.pendulum;
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          PreviewScene(
            mode: widget.mode,
            frameSize: _frameSize,
            t: _state.t,
            showGrid: widget.showGrid,
          ),
          VectorOverlay(
            state: _state,
            frameSize: _frameSize,
            massKg: 0.1,
            fit: PreviewScene.fit,
            showTrail: widget.animate,
            showLabels: widget.showLabels,
            tether: isPendulum
                ? PreviewScene.tetherFor(widget.mode, _frameSize)
                : null,
          ),
        ],
      ),
    );
  }
}
