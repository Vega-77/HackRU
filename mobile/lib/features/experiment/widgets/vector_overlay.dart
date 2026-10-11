import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/physics_state.dart';
import '../../../models/session_config.dart';
import '../../../models/vec2.dart';
import 'overlay_frame.dart';
import 'vector_overlay_painter.dart';

/// Live camera fixes snap to the marker; vectors ease between backend updates.
///
/// Sits on top of the camera preview (or a home screen preview) and must be
/// given the same [fit], so frame pixels line up with what the user sees.
///
/// Animation stops by itself once the arrows have caught up, and is
/// skipped entirely when the system asks for reduced motion.
///
/// With a [liveBox], the marker sits on that box instead of easing
/// towards the backend's position, since it is where the object is on the
/// newest camera frame.
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
    this.liveBox,
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

  /// The object's box on the newest camera frame, frame pixels, from
  /// on-device tracking in the AR camera.
  final ValueListenable<PixelRect?>? liveBox;

  @override
  State<VectorOverlay> createState() => _VectorOverlayState();
}

class _VectorOverlayState extends State<VectorOverlay>
    with SingleTickerProviderStateMixin {
  static const _trailLength = 10;
  static const _trailSpacing = Duration(milliseconds: 90);

  final _frame = ValueNotifier<OverlayFrame>(OverlayFrame.empty);
  final _trail = ValueNotifier<List<TrailDot>>(const []);
  final _trailPoints = ListQueue<Vec2>();

  late final Ticker _ticker = createTicker(_onTick);

  /// Where the newest state puts things, and the same moved onto the live
  /// box when there is one.
  OverlayFrame _stateTarget = OverlayFrame.empty;
  OverlayFrame _target = OverlayFrame.empty;
  Duration _lastTick = Duration.zero;
  Duration _sinceTrailDot = Duration.zero;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    widget.liveBox?.addListener(_onLiveBox);
    _stateTarget = OverlayFrame.fromState(widget.state);
    _target = _onLive(_stateTarget);
    _frame.value = _target;
    _addTrailPoint(force: true);
  }

  @override
  void didUpdateWidget(VectorOverlay old) {
    super.didUpdateWidget(old);
    if (!identical(widget.liveBox, old.liveBox)) {
      old.liveBox?.removeListener(_onLiveBox);
      widget.liveBox?.addListener(_onLiveBox);
      _onLiveBox();
    }
    if (!identical(widget.state, old.state)) _retarget();
  }

  /// [frame] moved onto the live box, if there is one and [frame] has the
  /// object at all.
  OverlayFrame _onLive(OverlayFrame frame) {
    final box = widget.liveBox?.value;
    if (box == null || frame.pixel == null) return frame;
    return frame.movedTo(box.centre, math.max(box.w, box.h) / 2);
  }

  void _onLiveBox() {
    _target = _onLive(_stateTarget);
    final live = widget.liveBox?.value == null ? null : _target.pixel;
    final shown = _frame.value;
    // No easing onto the box: it is already where the object is. Losing it
    // eases back to the backend's position.
    if (live != null && shown.pixel != null) {
      _frame.value = shown.movedTo(live, _target.markerRadius);
    }
    if (_reduceMotion) {
      if (live == null) _frame.value = _target;
      return;
    }
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _retarget() {
    _stateTarget = OverlayFrame.fromState(widget.state);
    _target = _onLive(_stateTarget);
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
      positionT: widget.liveBox?.value == null
          ? rate(AppMotion.markerSmoothing)
          : 1,
    );
    _frame.value = next;

    _sinceTrailDot += dt;
    if (_sinceTrailDot >= _trailSpacing) {
      _sinceTrailDot = Duration.zero;
      _addTrailPoint();
    }

    // A followed object keeps moving, and the trail with it.
    if (next.settledOn(_target) && widget.liveBox?.value == null) {
      _frame.value = _target;
      _ticker.stop();
    }
  }

  void _addTrailPoint({bool force = false}) {
    if (!widget.showTrail) return;
    // The trail records targets backed by a camera fix. It never samples the
    // marker while it eases between backend and on-device observations.
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
    widget.liveBox?.removeListener(_onLiveBox);
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
