import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/experiment_mode.dart';
import 'investigation.dart';

class InvestigationIndex extends StatelessWidget {
  const InvestigationIndex({
    super.key,
    required this.selected,
    required this.onSelect,
  });
  final ExperimentMode selected;
  final ValueChanged<ExperimentMode> onSelect;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final item in Investigation.all)
        _InvestigationRow(
          item: item,
          selected: selected == item.mode,
          onTap: () => onSelect(item.mode),
        ),
    ],
  );
}

class _InvestigationRow extends StatefulWidget {
  const _InvestigationRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });
  final Investigation item;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_InvestigationRow> createState() => _InvestigationRowState();
}

class _InvestigationRowState extends State<_InvestigationRow> {
  bool hovered = false;
  bool focused = false;
  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final ink = active ? AppColors.instrumentAccentDark : AppColors.vellum;
    return Semantics(
      selected: active,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('select-${widget.item.mode.name}'),
          onTap: widget.onTap,
          onHover: (value) => setState(() => hovered = value),
          onFocusChange: (value) => setState(() => focused = value),
          focusColor: AppColors.ruleDark,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : AppMotion.quick,
            decoration: BoxDecoration(
              color: focused
                  ? AppColors.ruleDark
                  : active || hovered
                  ? AppColors.graphiteRaised
                  : Colors.transparent,
              border: Border(
                left: BorderSide(
                  color: focused
                      ? AppColors.vellum
                      : active
                      ? ink
                      : Colors.transparent,
                  width: 3,
                ),
                bottom: const BorderSide(color: AppColors.ruleDark),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Row(
              children: [
                Text(
                  widget.item.number,
                  style: AppType.readoutSmall.copyWith(
                    color: AppColors.inkMutedDark,
                  ),
                ),
                const SizedBox(width: 16),
                CustomPaint(
                  size: const Size(40, 40),
                  painter: InvestigationSymbol(widget.item.mode, ink),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.mode.label,
                        style: AppType.title.copyWith(fontSize: 19, color: ink),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.item.description,
                        style: AppType.caption.copyWith(
                          color: AppColors.inkMutedDark,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  active
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: active ? ink : AppColors.inkMutedDark,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class InvestigationSymbol extends CustomPainter {
  InvestigationSymbol(this.mode, this.color);
  final ExperimentMode mode;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 40, size.height / 40);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    switch (mode) {
      case ExperimentMode.freeFall:
        canvas.drawPath(
          Path()
            ..moveTo(5, 31)
            ..quadraticBezierTo(18, -9, 33, 31),
          pen,
        );
        canvas.drawCircle(const Offset(25, 12), 4, Paint()..color = color);
        canvas.drawLine(const Offset(34, 6), const Offset(34, 21), pen);
        canvas.drawPath(
          Path()
            ..moveTo(31, 18)
            ..lineTo(34, 21)
            ..lineTo(37, 18),
          pen,
        );
      case ExperimentMode.ramp:
        canvas.drawPath(
          Path()
            ..moveTo(4, 12)
            ..lineTo(36, 31)
            ..lineTo(4, 31)
            ..close(),
          pen,
        );
        canvas.save();
        canvas.translate(16, 15);
        canvas.rotate(math.pi / 6);
        canvas.drawRect(const Rect.fromLTWH(-5, -8, 10, 8), pen);
        canvas.restore();
      case ExperimentMode.pendulum:
        canvas.drawLine(const Offset(9, 5), const Offset(31, 5), pen);
        canvas.drawLine(const Offset(20, 5), const Offset(32, 29), pen);
        canvas.drawArc(
          const Rect.fromLTWH(-6, -21, 52, 52),
          .9,
          1.3,
          false,
          pen,
        );
        canvas.drawCircle(const Offset(32, 29), 4, Paint()..color = color);
      case ExperimentMode.collision:
        canvas.drawRect(const Rect.fromLTWH(3, 16, 11, 10), pen);
        canvas.drawRect(const Rect.fromLTWH(26, 12, 12, 14), pen);
        canvas.drawLine(const Offset(15, 21), const Offset(23, 21), pen);
        canvas.drawPath(
          Path()
            ..moveTo(20, 18)
            ..lineTo(23, 21)
            ..lineTo(20, 24),
          pen,
        );
        canvas.drawLine(const Offset(3, 30), const Offset(38, 30), pen);
    }
  }

  @override
  bool shouldRepaint(InvestigationSymbol old) =>
      old.mode != mode || old.color != color;
}
