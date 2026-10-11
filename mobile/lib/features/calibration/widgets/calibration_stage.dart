import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/logging/debug_log.dart';
import '../../../models/calibration.dart';
import '../../../models/physics_state.dart';
import '../../../models/session_config.dart';
import '../../../models/vec2.dart';
import '../../../state/calibration_controller.dart';
import '../../../state/session_controller.dart';
import '../../../state/experiment_settings.dart';
import '../../../services/network/acquisition_client.dart';
import '../../experiment/widgets/coordinate_mapper.dart';
import 'selection_region_painter.dart';

/// The picture with the calibration marks on it:
///
/// * a ruler line with two draggable ends, which you lay over a real ruler;
/// * a target ring where you tapped the object to track.
///
/// While you drag an end, a loupe above your finger shows the end magnified,
/// so you can place it on a millimetre mark. The line snaps level or upright
/// within a few degrees, since real rulers usually are.
///
/// All positions are stored in frame pixels, so they match what the backend
/// sees whatever size this widget is.
class CalibrationStage extends ConsumerStatefulWidget {
  const CalibrationStage({
    super.key,
    required this.frameSize,
    required this.fit,
    required this.background,
  });

  final FrameSize frameSize;

  /// How [background] fills the stage; marks are mapped with the same fit.
  final BoxFit fit;
  final Widget background;

  @override
  ConsumerState<CalibrationStage> createState() => _CalibrationStageState();
}

enum _End { start, end }

class _CalibrationStageState extends ConsumerState<CalibrationStage> {
  /// How close (screen px) a touch must be to grab a ruler end. Generous,
  /// because the end itself is small and your finger covers it.
  static const _grabRadius = 36.0;
  static const _snapDegrees = 4.0;
  static const _loupeSize = 108.0;
  static const _loupeLift = 96.0;

  _End? _dragging;
  Offset _grabOffset = Offset.zero;
  bool _snapped = false;
  Vec2? _boxStart;
  Vec2? _boxEnd;
  Future<EncodedFrame?>? _selectionCapture;
  EncodedFrame? _previewFrame;
  int _selectionEpoch = 0;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    // Back from an experiment, a confirmed selection's picture is old: show
    // the live camera rather than a still that looks frozen.
    _previewFrame = _heldFrame(ref.read(calibrationProvider));
  }

  /// The picture to hold when no gesture is in progress: the selection's,
  /// while it waits for the user to confirm it, else none (live camera).
  static EncodedFrame? _heldFrame(Calibration c) =>
      c.target == null || c.selectionConfirmed ? null : c.selectionFrame;

  KeyEventResult _onKey(
    KeyEvent event,
    CoordinateMapper mapper,
    Calibration c,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      final point = mapper.clampToVisible(
        mapper.toFrame(
          Offset(mapper.viewSize.width / 2, mapper.viewSize.height / 2),
        ),
      );
      final epoch = ++_selectionEpoch;
      _freezeSelection(epoch).then((frame) {
        if (!mounted || frame == null || epoch != _selectionEpoch) return;
        final x = (point.x - 16).clamp(0.0, widget.frameSize.width - 32.0);
        final y = (point.y - 16).clamp(0.0, widget.frameSize.height - 32.0);
        ref
            .read(calibrationProvider.notifier)
            .selectObject(Vec2(x + 16, y + 16), PixelRect(x, y, 32, 32), frame);
      });
      return KeyEventResult.handled;
    }
    final box = c.targetBbox, frame = c.selectionFrame;
    if (box == null || frame == null) return KeyEventResult.ignored;
    var x = box.x, y = box.y, w = box.w, h = box.h;
    if (key == LogicalKeyboardKey.arrowLeft) {
      x -= 1;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      x += 1;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      y -= 1;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      y += 1;
    } else if (key == LogicalKeyboardKey.equal) {
      w += 2;
      h += 2;
    } else if (key == LogicalKeyboardKey.minus) {
      w -= 2;
      h -= 2;
    } else {
      return KeyEventResult.ignored;
    }
    w = w.clamp(8.0, widget.frameSize.width.toDouble());
    h = h.clamp(8.0, widget.frameSize.height.toDouble());
    x = x.clamp(0.0, widget.frameSize.width - w);
    y = y.clamp(0.0, widget.frameSize.height - h);
    ref
        .read(calibrationProvider.notifier)
        .selectObject(Vec2(x + w / 2, y + h / 2), PixelRect(x, y, w, h), frame);
    return KeyEventResult.handled;
  }

  Future<EncodedFrame?> _freezeSelection(int epoch) async {
    if (_previewFrame != null) return _previewFrame;
    EncodedFrame? frame;
    try {
      frame = await ref.read(frameSourceProvider).capture();
    } catch (error, stack) {
      log.w('Could not capture the selection picture', error, stack);
      if (mounted && epoch == _selectionEpoch) {
        ref
            .read(calibrationProvider.notifier)
            .acquisitionFailed(
              'Could not capture the picture. Tap the object again to retry.',
            );
      }
      return null;
    }
    if (!mounted || epoch != _selectionEpoch) return null;
    if (frame == null) {
      ref
          .read(calibrationProvider.notifier)
          .acquisitionFailed(
            'The camera has no picture yet. Wait a moment, then try again.',
          );
      return null;
    }
    setState(() => _previewFrame = frame);
    return frame;
  }

  @override
  Widget build(BuildContext context) {
    final calibration = ref.watch(calibrationProvider);
    ref.listen(calibrationProvider, (previous, next) {
      if (previous?.target != null && next.target == null) {
        _selectionEpoch++;
        setState(() => _previewFrame = null);
      } else if (next.selectionConfirmed &&
          !(previous?.selectionConfirmed ?? false)) {
        // Confirmed: back to the live camera, to check the object is in
        // view before starting.
        setState(() => _previewFrame = null);
      }
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final view = constraints.biggest;
        final mapper = CoordinateMapper(
          frameSize: widget.frameSize,
          viewSize: view,
          fit: widget.fit,
        );
        Offset? screen(Vec2? p) => p == null ? null : mapper.toScreen(p);
        final active = switch (_dragging) {
          _End.start => screen(calibration.rulerStart),
          _End.end => screen(calibration.rulerEnd),
          null => null,
        };

        return Focus(
          onFocusChange: (value) => setState(() => _focused = value),
          onKeyEvent: (_, event) => _onKey(event, mapper, calibration),
          child: Semantics(
            label: _describe(calibration),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _onTap(d.localPosition, mapper, calibration),
              onPanStart: (d) =>
                  _onPanStart(d.localPosition, mapper, calibration),
              onPanUpdate: (d) =>
                  _onPanUpdate(d.localPosition, mapper, calibration),
              onPanEnd: (_) => _onPanEnd(),
              onPanCancel: () {
                _selectionEpoch++;
                setState(() {
                  _dragging = null;
                  _boxStart = null;
                  _boxEnd = null;
                  _previewFrame = _heldFrame(calibration);
                });
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_previewFrame != null)
                    Image.memory(_previewFrame!.jpeg, fit: widget.fit)
                  else
                    widget.background,
                  if (_boxStart != null && _boxEnd != null)
                    IgnorePointer(
                      child: CustomPaint(
                        painter: SelectionRegionPainter(
                          box: Rect.fromPoints(
                            screen(_boxStart)!,
                            screen(_boxEnd)!,
                          ),
                          drawing: true,
                        ),
                      ),
                    ),
                  CustomPaint(
                    painter: _MarksPainter(
                      start: screen(calibration.rulerStart),
                      end: screen(calibration.rulerEnd),
                      target: screen(calibration.target),
                      targetBox: calibration.targetBbox == null
                          ? null
                          : mapper.rectToScreen(calibration.targetBbox!),
                      label: _lengthLabel(calibration.rulerLengthM),
                      active: _dragging,
                      snapped: _snapped,
                      confirmed: calibration.selectionConfirmed,
                    ),
                  ),
                  if (active != null) _loupe(active, view),
                  if (_focused)
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: AppColors.graphiteDeep,
                            width: 4,
                          ),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: AppColors.vellum,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The magnifier, above the finger, or below it near the top edge.
  Widget _loupe(Offset point, Size view) {
    final above = point.dy - _loupeLift - _loupeSize / 2 > 0;
    final centre = Offset(
      point.dx.clamp(_loupeSize / 2, view.width - _loupeSize / 2),
      point.dy + (above ? -_loupeLift : _loupeLift),
    );
    return Positioned(
      left: centre.dx - _loupeSize / 2,
      top: centre.dy - _loupeSize / 2,
      child: IgnorePointer(
        child: RawMagnifier(
          size: const Size.square(_loupeSize),
          magnificationScale: 2.5,
          focalPointOffset: point - centre,
          decoration: const MagnifierDecoration(
            shape: CircleBorder(
              side: BorderSide(color: AppColors.vellum, width: 2),
            ),
            shadows: [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _End? _endNear(Offset touch, CoordinateMapper mapper, Calibration c) {
    double distance(Vec2? p) =>
        p == null ? double.infinity : (mapper.toScreen(p) - touch).distance;
    final toStart = distance(c.rulerStart);
    final toEnd = distance(c.rulerEnd);
    if (math.min(toStart, toEnd) > _grabRadius) return null;
    return toStart <= toEnd ? _End.start : _End.end;
  }

  Future<void> _onTap(
    Offset touch,
    CoordinateMapper mapper,
    Calibration c,
  ) async {
    // A tap on a ruler end is a missed drag, not a new target.
    if (_endNear(touch, mapper, c) != null) return;
    HapticFeedback.selectionClick();
    final epoch = ++_selectionEpoch;
    final frame = await _freezeSelection(epoch);
    if (!mounted || frame == null || epoch != _selectionEpoch) return;
    final point = mapper.clampToVisible(mapper.toFrame(touch));
    final controller = ref.read(calibrationProvider.notifier);
    controller.beginAcquisition(point, frame);
    try {
      final proposal = await ref
          .read(acquisitionClientProvider)
          .propose(
            ref.read(experimentSettingsProvider).backendUrl,
            point,
            frame,
          );
      if (!mounted || epoch != _selectionEpoch) return;
      log.i(
        'Acquisition proposal: ${proposal.reason}, box ${proposal.box?.toJson()}',
      );
      if (proposal.box case final box?) {
        controller.selectObject(point, box, frame);
      } else {
        controller.acquisitionFailed(
          'No clear object boundary at this point. Draw a box around the object, or retry.',
        );
      }
    } catch (error, stack) {
      if (!mounted || epoch != _selectionEpoch) return;
      log.w('Object acquisition request failed', error, stack);
      controller.acquisitionFailed(
        'Could not reach object selection. Check the backend connection and retry, or draw a box.',
      );
    }
  }

  void _onPanStart(Offset touch, CoordinateMapper mapper, Calibration c) {
    final end = _endNear(touch, mapper, c);
    if (end == null) {
      final epoch = ++_selectionEpoch;
      _selectionCapture = _freezeSelection(epoch);
      setState(() {
        _boxStart = mapper.clampToVisible(mapper.toFrame(touch));
        _boxEnd = _boxStart;
      });
      return;
    }
    final p = end == _End.start ? c.rulerStart! : c.rulerEnd!;
    HapticFeedback.lightImpact();
    setState(() {
      _dragging = end;
      // Keep the end where it was under the finger, instead of jumping.
      _grabOffset = mapper.toScreen(p) - touch;
    });
  }

  void _onPanUpdate(Offset touch, CoordinateMapper mapper, Calibration c) {
    final end = _dragging;
    if (end == null) {
      if (_boxStart != null) {
        setState(() => _boxEnd = mapper.clampToVisible(mapper.toFrame(touch)));
      }
      return;
    }
    var p = mapper.clampToVisible(mapper.toFrame(touch + _grabOffset));
    final other = end == _End.start ? c.rulerEnd : c.rulerStart;

    var snapped = false;
    if (other != null) {
      final snap = _snap(p, other);
      if (snap != null) {
        p = mapper.clampToVisible(snap);
        snapped = true;
      }
    }
    if (snapped && !_snapped) HapticFeedback.selectionClick();
    if (snapped != _snapped) setState(() => _snapped = snapped);

    final controller = ref.read(calibrationProvider.notifier);
    end == _End.start ? controller.setRulerStart(p) : controller.setRulerEnd(p);
  }

  Future<void> _onPanEnd() async {
    if (_dragging == null) {
      final start = _boxStart, end = _boxEnd;
      final epoch = _selectionEpoch;
      final frame = await _selectionCapture;
      if (!mounted || epoch != _selectionEpoch) return;
      setState(() {
        _boxStart = null;
        _boxEnd = null;
      });
      final box = start == null || end == null
          ? null
          : PixelRect(
              math.min(start.x, end.x),
              math.min(start.y, end.y),
              (start.x - end.x).abs(),
              (start.y - end.y).abs(),
            );
      if (frame == null || box == null || box.w < 8 || box.h < 8) {
        // Too small to be a box, or no picture: let go of the picture held
        // for drawing, or the stage stays on it.
        setState(
          () => _previewFrame = _heldFrame(ref.read(calibrationProvider)),
        );
        return;
      }
      ref
          .read(calibrationProvider.notifier)
          .selectObject(Vec2(box.x + box.w / 2, box.y + box.h / 2), box, frame);
      return;
    }
    setState(() {
      _dragging = null;
      _snapped = false;
    });
  }

  /// Levels [p] with [other] if the line is within a few degrees of
  /// horizontal or vertical.
  static Vec2? _snap(Vec2 p, Vec2 other) {
    final d = p - other;
    if (d.length < 8) return null;
    final degrees = math.atan2(d.y.abs(), d.x.abs()) * 180 / math.pi;
    if (degrees < _snapDegrees) return Vec2(p.x, other.y);
    if (degrees > 90 - _snapDegrees) return Vec2(other.x, p.y);
    return null;
  }

  static String _lengthLabel(double metres) {
    final cm = metres * 100;
    final text = cm == cm.roundToDouble()
        ? cm.toStringAsFixed(0)
        : cm.toStringAsFixed(1);
    return '$text cm';
  }

  static String _describe(Calibration c) {
    final scale = c.pxPerM;
    return [
      'Calibration picture.',
      if (scale != null)
        'Ruler line set to ${_lengthLabel(c.rulerLengthM)}, '
            '${scale.round()} pixels per metre.',
      c.target == null ? 'No object marked.' : 'Object marked.',
      'Enter selects a box. Arrow keys move it. Plus and minus resize it.',
    ].join(' ');
  }
}

/// Draws the ruler as a drafting dimension line, plus the target ring.
/// Neutral ink only: colour on these screens means a physical quantity.
class _MarksPainter extends CustomPainter {
  _MarksPainter({
    required this.start,
    required this.end,
    required this.target,
    this.targetBox,
    required this.label,
    required this.active,
    required this.snapped,
    required this.confirmed,
  });

  final Offset? start;
  final Offset? end;
  final Offset? target;
  final Rect? targetBox;
  final String label;
  final _End? active;
  final bool snapped;
  final bool confirmed;

  static const _ink = AppColors.vellum;
  static const _halo = Color(0x99000000);

  @override
  void paint(Canvas canvas, Size size) {
    if (target != null && targetBox == null) _paintTarget(canvas, target!);
    if (targetBox != null) {
      SelectionRegionPainter(
        box: targetBox!,
        confirmed: confirmed,
      ).paint(canvas, size);
    }
    if (start != null && end != null) _paintRuler(canvas, size, start!, end!);
  }

  void _paintRuler(Canvas canvas, Size size, Offset a, Offset b) {
    final d = b - a;
    final length = d.distance;
    final along = length < 1 ? const Offset(1, 0) : d / length;
    final across = Offset(-along.dy, along.dx);

    final halo = Paint()
      ..color = _halo
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final ink = Paint()
      ..color = _ink
      ..strokeWidth = snapped ? 2 : 1.5
      ..strokeCap = StrokeCap.round;

    // The line, with end ticks across it like a dimension on a drawing.
    for (final paint in [halo, ink]) {
      canvas.drawLine(a, b, paint);
      for (final p in [a, b]) {
        canvas.drawLine(p - across * 12, p + across * 12, paint);
      }
    }

    // The centre remains the exact endpoint; the larger outline aids touch.
    for (final (point, which) in [(a, _End.start), (b, _End.end)]) {
      final grabbed = active == which;
      final radius = grabbed ? 13.0 : 10.0;
      canvas.drawCircle(point, radius + 1.5, Paint()..color = _halo);
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = grabbed ? AppColors.instrumentAccentDark : _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawCircle(point, 1.8, Paint()..color = _ink);
      final endpoint = TextPainter(
        text: TextSpan(
          text: which == _End.start ? 'A' : 'B',
          style: AppType.label.copyWith(color: _ink),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = (point.dx - endpoint.width / 2)
          .clamp(4.0, math.max(4.0, size.width - endpoint.width - 4))
          .toDouble();
      final y = (point.dy + 18)
          .clamp(4.0, math.max(4.0, size.height - endpoint.height - 4))
          .toDouble();
      final tag = Rect.fromLTWH(
        x - 4,
        y - 2,
        endpoint.width + 8,
        endpoint.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(tag, const Radius.circular(3)),
        Paint()..color = AppColors.graphiteDeep,
      );
      endpoint.paint(canvas, Offset(x, y));
    }

    // Place the reference length beside the dimension, away from its ends.
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: AppType.readoutSmall.copyWith(
          color: AppColors.graphiteDeep,
          fontSize: 13,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Put it on whichever side of the line is "up" on screen, unless that
    // runs off the picture; then below, and never past the sides.
    final up = across.dy > 0 ? -across : across;
    final gap = text.height / 2 + 14;
    final pillSize = Size(text.width + 16, text.height + 8);
    final bounds = Offset.zero & size;
    var centre = (a + b) / 2 + up * gap;
    if (!bounds.contains(centre - Offset(0, pillSize.height / 2))) {
      centre = (a + b) / 2 - up * gap;
    }
    final halfW = pillSize.width / 2;
    if (size.width > pillSize.width) {
      centre = Offset(centre.dx.clamp(halfW, size.width - halfW), centre.dy);
    }
    final halfH = pillSize.height / 2;
    if (size.height > pillSize.height) {
      centre = Offset(centre.dx, centre.dy.clamp(halfH, size.height - halfH));
    }
    final pill = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: centre,
        width: pillSize.width,
        height: pillSize.height,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(pill, Paint()..color = _ink);
    text.paint(canvas, centre - Offset(text.width / 2, text.height / 2));
  }

  void _paintTarget(Canvas canvas, Offset p) {
    const r = 18.0;
    final halo = Paint()
      ..color = _halo
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    final ink = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final paint in [halo, ink]) {
      canvas.drawCircle(p, r, paint);
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) =>
      old.start != start ||
      old.end != end ||
      old.target != target ||
      old.targetBox != targetBox ||
      old.label != label ||
      old.active != active ||
      old.snapped != snapped ||
      old.confirmed != confirmed;
}
