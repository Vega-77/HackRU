import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/calibration.dart';
import '../../../models/session_config.dart';
import '../../../state/calibration_controller.dart';
import '../../../state/session_controller.dart';

String selectionStatus(Calibration c) {
  if (c.selectionPending) return 'Finding boundary';
  if (c.selectionError != null) return 'Selection needs attention';
  if (c.selectionConfirmed) return 'Region confirmed';
  if (c.targetBbox != null) return 'Review selection';
  return 'No object selected';
}

class WorkspaceHeading extends StatelessWidget {
  const WorkspaceHeading({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Measurement workspace',
          style: AppType.display.copyWith(fontSize: 30),
        ),
        const SizedBox(height: 8),
        Text(
          'Establish a distance. Isolate your object. Prepare the measurement.',
          style: AppType.body.copyWith(color: AppColors.inkMutedDark),
        ),
      ],
    ),
  );
}

class CameraStatusStrip extends ConsumerWidget {
  const CameraStatusStrip({
    super.key,
    required this.frame,
    required this.unavailable,
  });
  final FrameSize? frame;
  final bool unavailable;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(calibrationProvider);
    final phase = ref.watch(sessionProvider.select((s) => s.phase));
    final label = phase == SessionPhase.starting
        ? 'Initializing experiment'
        : selectionStatus(c);
    return Container(
      width: double.infinity,
      color: AppColors.graphiteRaised,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 16,
        runSpacing: 4,
        children: [
          Text(
            unavailable
                ? 'Camera unavailable'
                : frame == null
                ? 'Opening camera'
                : '${frame!.width} × ${frame!.height} px',
            style: AppType.readoutSmall.copyWith(color: AppColors.inkMutedDark),
          ),
          Text(
            label,
            style: AppType.caption.copyWith(
              color: c.selectionConfirmed
                  ? AppColors.instrumentAccentDark
                  : AppColors.vellum,
            ),
          ),
        ],
      ),
    );
  }
}

class WorkspaceFooter extends ConsumerWidget {
  const WorkspaceFooter({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(calibrationProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
      child: Wrap(
        spacing: 28,
        runSpacing: 8,
        children: [
          Text(
            c.selectionFrame == null
                ? 'Live picture'
                : 'Selection picture held',
            style: AppType.label.copyWith(color: AppColors.vellum),
          ),
          Text(
            c.surface != null
                ? 'AR surface calibration'
                : c.pxPerM == null
                ? 'Scale not established'
                : '${c.pxPerM!.toStringAsFixed(1)} px/m',
            style: AppType.readoutSmall.copyWith(color: AppColors.inkMutedDark),
          ),
          Text(
            'Redraw the region to adjust it.',
            style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
          ),
        ],
      ),
    );
  }
}

class MeasurementSection extends StatelessWidget {
  const MeasurementSection({
    super.key,
    required this.number,
    required this.total,
    required this.title,
    required this.body,
    required this.done,
    this.trailing,
    this.footer,
    this.last = false,
  });
  final int number;
  final int total;
  final String title, body;
  final bool done, last;
  final Widget? trailing, footer;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: 'Step $number of $total${done ? ', done' : ', incomplete'}',
    child: AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppMotion.standard,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      decoration: BoxDecoration(
        color: done ? AppColors.graphiteRaised : Colors.transparent,
        border: Border(
          left: BorderSide(
            width: 2,
            color: done ? AppColors.instrumentAccentDark : AppColors.ruleDark,
          ),
          bottom: const BorderSide(color: AppColors.ruleDark),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                number.toString().padLeft(2, '0'),
                style: AppType.readoutSmall.copyWith(
                  color: AppColors.instrumentAccentDark,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: AppType.title.copyWith(fontSize: 19)),
              ),
              if (done)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.check,
                    size: 18,
                    color: AppColors.instrumentAccentDark,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: AppType.caption.copyWith(
              fontSize: 13,
              color: AppColors.inkMutedDark,
            ),
          ),
          if (trailing != null) ...[const SizedBox(height: 16), trailing!],
          if (footer != null) ...[const SizedBox(height: 12), footer!],
        ],
      ),
    ),
  );
}

class MeasurementValue extends StatelessWidget {
  const MeasurementValue({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
  });
  final String label, value, unit;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
      ),
      const SizedBox(height: 8),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 6,
        children: [
          Text(value, style: AppType.readout.copyWith(color: AppColors.vellum)),
          Text(
            unit,
            style: AppType.label.copyWith(color: AppColors.inkMutedDark),
          ),
        ],
      ),
    ],
  );
}
