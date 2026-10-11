import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/physics_state.dart';
import '../../../models/session_config.dart';
import '../../../models/vec2.dart';
import 'overlay_frame.dart';
import 'vector_overlay_painter.dart';

/// Observed positions snap to the latest frame; vector lengths ease between updates.
///
/// Sits on top of the camera preview (or a home screen preview) and must be
/// given the same [fit], so frame pixels line up with what the user sees.
///
/// Animation stops by itself once the arrows have caught up, and is
/// skipped entirely when the system asks for reduced motion.
class VectorOverlay extends StatefulWidget {
  const VectorOverlay({
    super.key,
    required this.state,
    required this.frameSize,
    required this.massKg,
    this.fit = BoxFit.cover,
    this.layers = const OverlayLayers(),
    this.showTrail = true,
    this.tether,
    this.showLabels = true,
    this.haloColor = AppColors.graphiteDeep,
    this.markerColor = AppColors.vellum,
  });

  final PhysicsState? state;
  final FrameSize frameSize;
  final double massKg;
  final BoxFit fit;
  final OverlayLayers layers;

  /// Stroboscopic dots at the object's recent positions, like a multi-flash
  /// photo in a textbook.
  final bool showTrail;

  /// Frame pixel the object hangs from (pendulum pivot), if any.
  final Vec2? tether;
  final bool showLabels;
  final Color haloColor;
  final Color markerColor;

  @override
  State<VectorOverlay> createState() => _VectorOverlayState();
}

class _VectorOverlayState extends State<VectorOverlay>
    with SingleTickerProviderStateMixin {
  static const _trailLength = 10;

  final _frame = ValueNotifier<OverlayFrame>(OverlayFrame.empty);
  final _trail = ValueNotifier<List<TrailDot>>(const []);
  final _trailPoints = ListQueue<Vec2>();

  late final Ticker _ticker = createTicker(_onTick);
  OverlayFrame _target = OverlayFrame.empty;
  Duration _lastTick = Duration.zero;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _target = OverlayFrame.fromState(widget.state);
    _frame.value = _target;
    _addTrailPoint(force: true);
  }

  @override
  void didUpdateWidget(VectorOverlay old) {
    super.didUpdateWidget(old);
    if (!identical(widget.state, old.state)) _retarget();
  }

  void _retarget() {
    _target = OverlayFrame.fromState(widget.state);
    if (_target.pixel == null) {
      _clearTrail();
      _frame.value = OverlayFrame.empty;
      _ticker.stop();
      return;
    }
    _addTrailPoint();

    if (_reduceMotion) {
      _frame.value = _target;
      return;
    }
    _frame.value = _frame.value.approach(_target, vectorT: 0, positionT: 1);
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    // Convert per-60 Hz-tick rates to this tick's real duration, so the
    // easing feels the same on a 60 Hz and a 120 Hz screen.
    final ticks = dt.inMicroseconds / (1e6 / 60);
    double rate(double perTick) => 1 - math.pow(1 - perTick, ticks).toDouble();

    final next = _frame.value.approach(
      _target,
      vectorT: rate(AppMotion.arrowSmoothing),
      positionT: 1,
    );
    _frame.value = next;

    if (next.settledOn(_target)) {
      _frame.value = _target;
      _ticker.stop();
    }
  }

  void _addTrailPoint({bool force = false}) {
    if (!widget.showTrail) return;
    final p = _target.pixel;
    if (p == null) return;
    // A still object leaves one dot, not a pile of them.
    if (!force &&
        _trailPoints.isNotEmpty &&
        _trailPoints.last.distanceTo(p) < 1.5) {
      return;
    }
    _trailPoints.addLast(p);
    while (_trailPoints.length > _trailLength) {
      _trailPoints.removeFirst();
    }
    final n = _trailPoints.length;
    _trail.value = [
      // Skip the newest point: the marker is already there.
      for (var i = 0; i < n - 1; i++)
        TrailDot(_trailPoints.elementAt(i), (n - 1 - i) / _trailLength),
    ];
  }

  void _clearTrail() {
    _trailPoints.clear();
    _trail.value = const [];
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    _trail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: VectorOverlayPainter(
            frame: _frame,
            trail: widget.showTrail ? _trail : null,
            tether: widget.tether,
            frameSize: widget.frameSize,
            fit: widget.fit,
            massKg: widget.massKg,
            layers: widget.layers,
            showLabels: widget.showLabels,
            haloColor: widget.haloColor,
            markerColor: widget.markerColor,
            textScale: MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.3),
          ),
        ),
      ),
    );
  }
}
