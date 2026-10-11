import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/experiment_mode.dart';
import 'experiment_preview.dart';
import 'investigation.dart';
import 'laboratory_diagram.dart';
import 'preview_physics.dart';

class LaboratoryExhibit extends StatefulWidget {
  const LaboratoryExhibit({
    super.key,
    required this.mode,
    required this.onStart,
    required this.onLearn,
  });
  final ExperimentMode mode;
  final VoidCallback onStart;
  final VoidCallback onLearn;
  @override
  State<LaboratoryExhibit> createState() => _LaboratoryExhibitState();
}

class _LaboratoryExhibitState extends State<LaboratoryExhibit>
    with SingleTickerProviderStateMixin {
  late final Ticker ticker = createTicker(_tick);
  bool playing = true, forces = false;
  late double time = ExperimentPreview.stillTime(widget.mode);
  Duration last = Duration.zero;
  bool get reduced => MediaQuery.disableAnimationsOf(context);
  void _tick(Duration elapsed) {
    final dt = elapsed - last;
    last = elapsed;
    setState(() => time += dt.inMicroseconds / 1e6);
  }

  void _sync() {
    if (playing && !reduced && !ticker.isActive) {
      last = Duration.zero;
      ticker.start();
    } else if ((!playing || reduced) && ticker.isActive) {
      ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(LaboratoryExhibit old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      time = ExperimentPreview.stillTime(widget.mode);
    }
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = Investigation.forMode(widget.mode);
    final sample = PreviewPhysics.sample(widget.mode, time);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Investigation ${item.number}',
                    style: AppType.label.copyWith(
                      color: AppColors.instrumentAccentDark,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Illustrative model',
                    style: AppType.caption.copyWith(
                      color: AppColors.inkMutedDark,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              tooltip: reduced
                  ? 'Motion reduced by system setting'
                  : playing
                  ? 'Pause model'
                  : 'Play model',
              onPressed: reduced
                  ? null
                  : () {
                      setState(() => playing = !playing);
                      _sync();
                    },
              icon: Icon(
                playing && !reduced ? Icons.pause : Icons.play_arrow,
                size: 20,
              ),
            ),
            IconButton(
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              tooltip: 'Replay model',
              onPressed: () => setState(
                () => time = reduced
                    ? ExperimentPreview.stillTime(widget.mode)
                    : 0,
              ),
              icon: const Icon(Icons.replay, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: reduced ? Duration.zero : AppMotion.standard,
          child: Align(
            key: ValueKey(item.mode),
            alignment: Alignment.centerLeft,
            child: Text(
              item.question,
              style: AppType.title.copyWith(
                fontSize: 26,
                color: AppColors.vellum,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.graphiteDeep,
            border: Border(
              top: BorderSide(color: AppColors.ruleDark),
              bottom: BorderSide(color: AppColors.ruleDark),
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Model / SI units',
                        style: AppType.caption.copyWith(
                          color: AppColors.inkMutedDark,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      't ${time.toStringAsFixed(2)} s',
                      style: AppType.readoutSmall.copyWith(
                        color: AppColors.vellum,
                      ),
                    ),
                  ],
                ),
              ),
              Semantics(
                label:
                    '${widget.mode.label} diagram. ${item.conditions}. ${item.equation}. ${forces ? 'Force' : 'Motion'} vectors shown.',
                child: ExcludeSemantics(
                  child: LayoutBuilder(
                    builder: (context, constraints) => SizedBox(
                      height: MediaQuery.sizeOf(context).width >= 1280
                          ? constraints.maxWidth / 2.05
                          : (constraints.maxWidth / 1.35).clamp(280, 440),
                      child: RepaintBoundary(
                        child: ClipRect(
                          child: AnimatedSwitcher(
                            duration: reduced
                                ? Duration.zero
                                : AppMotion.standard,
                            child: CustomPaint(
                              key: ValueKey(widget.mode),
                              size: Size.infinite,
                              painter: LaboratoryDiagram(
                                widget.mode,
                                sample,
                                forces: forces,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final minimum = MediaQuery.textScalerOf(context).scale(96);
                    final columns =
                        ((constraints.maxWidth + 16) / (minimum + 16))
                            .floor()
                            .clamp(1, 3);
                    final width =
                        (constraints.maxWidth - 16 * (columns - 1)) / columns;
                    return Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        SizedBox(
                          width: width,
                          child: _Readout(
                            label: 'Speed',
                            value: sample.velocity!.length.toStringAsFixed(2),
                            unit: 'm/s',
                            color: AppColors.velocity,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _Readout(
                            label: 'Acceleration',
                            value: sample.acceleration!.length.toStringAsFixed(
                              2,
                            ),
                            unit: 'm/s²',
                            color: AppColors.acceleration,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _Readout(
                            label: 'Net force',
                            value: (sample.acceleration!.length * .1)
                                .toStringAsFixed(2),
                            unit: 'N',
                            color: AppColors.forceNet,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _LayerButton(
              label: 'Motion vectors',
              selected: !forces,
              onPressed: () => setState(() => forces = false),
            ),
            _LayerButton(
              label: 'Force vectors',
              selected: forces,
              onPressed: () => setState(() => forces = true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [
            if (!forces) ...[
              const _Legend('Velocity', AppColors.velocity),
              const _Legend('Acceleration', AppColors.acceleration),
            ] else ...[
              const _Legend('Net force', AppColors.forceNet),
              _Legend(
                widget.mode == ExperimentMode.ramp
                    ? 'Weight components / contact forces'
                    : 'Applied forces',
                AppColors.forceComponent,
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Vectors use separate display scales. Model mass: 0.10 kg.',
          style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
        ),
        const SizedBox(height: 24),
        _Equation(item),
        const SizedBox(height: 8),
        Text(
          item.conditions,
          style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.instrumentAccentDark,
              foregroundColor: AppColors.graphiteDeep,
              padding: const EdgeInsets.symmetric(vertical: 20),
              textStyle: AppType.bodyStrong,
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadii.controlAll,
              ),
            ),
            onPressed: widget.onStart,
            child: Text('Set up ${widget.mode.label.toLowerCase()}'),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Next: select your object and calibrate the camera.',
          style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
        ),
        const SizedBox(height: AppSpace.lg),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.vellum,
              side: const BorderSide(color: AppColors.ruleDark),
              padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
              textStyle: AppType.bodyStrong,
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadii.controlAll,
              ),
            ),
            onPressed: widget.onLearn,
            child: Text(
              'Learn the physics of ${widget.mode.label.toLowerCase()}',
            ),
          ),
        ),
      ],
    );
  }
}

class _Equation extends StatelessWidget {
  const _Equation(this.item);
  final Investigation item;
  @override
  Widget build(BuildContext context) {
    final style = AppType.title.copyWith(color: AppColors.vellum, fontSize: 22);
    if (item.mode != ExperimentMode.freeFall) {
      return Text(item.equation, style: style);
    }
    // Archivo has a Latin y, but no Unicode subscript-y glyph.
    return Semantics(
      label: 'Vertical acceleration equals negative g',
      child: ExcludeSemantics(
        child: Text.rich(
          TextSpan(
            style: style,
            children: [
              const TextSpan(text: 'a'),
              WidgetSpan(
                alignment: PlaceholderAlignment.bottom,
                child: Transform.translate(
                  offset: const Offset(0, 4),
                  child: Text('y', style: style.copyWith(fontSize: 14)),
                ),
              ),
              const TextSpan(text: ' = −g'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });
  final String label, value, unit;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(width: 3, height: 12, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 4,
        children: [
          Text(
            value,
            style: AppType.readout.copyWith(
              fontSize: 26,
              color: AppColors.vellum,
            ),
          ),
          Text(
            unit,
            style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
          ),
        ],
      ),
    ],
  );
}

class _LayerButton extends StatelessWidget {
  const _LayerButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: selected ? AppColors.vellum : AppColors.inkMutedDark,
        backgroundColor: selected ? AppColors.ruleDark : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.controlAll),
      ),
      onPressed: onPressed,
      child: Text(label),
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend(this.label, this.color);
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 16, height: 3, color: color),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          label,
          style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
        ),
      ),
    ],
  );
}
