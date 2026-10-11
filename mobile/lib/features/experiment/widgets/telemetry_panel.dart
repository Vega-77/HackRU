import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/tokens.dart';
import '../../../models/experiment_mode.dart';
import '../../../models/physics_state.dart';
import '../../../state/experiment_settings.dart';
import '../../../state/session_controller.dart';
import '../../../state/theory_check.dart';
import '../../debug/copy_debug_log.dart';
import 'energy_bars.dart';
import 'physics_symbol.dart';
import 'telemetry_chart.dart';

/// Everything below the picture: arrow toggles, live readouts, the
/// x/v/a chart and the energy audit.
///
/// Physics arrives at up to 30 Hz, but numbers that change faster than the
/// eye can read are noise, so this panel redraws at most every
/// [_refresh], and only when new data came in.
class TelemetryPanel extends ConsumerStatefulWidget {
  const TelemetryPanel({
    super.key,
    this.scrollController,
    this.showHandle = true,
  });

  /// From the surrounding `DraggableScrollableSheet`, if any.
  final ScrollController? scrollController;
  final bool showHandle;

  @override
  ConsumerState<TelemetryPanel> createState() => _TelemetryPanelState();
}

class _TelemetryPanelState extends ConsumerState<TelemetryPanel> {
  static const _refresh = Duration(milliseconds: 66);

  Timer? _timer;
  int _shownVersion = -1;
  ChartQuantity _quantity = ChartQuantity.velocity;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_refresh, (_) {
      if (!mounted) return;
      final version = ref.read(sessionProvider).telemetryVersion;
      if (version != _shownVersion) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(experimentSettingsProvider);
    final controller = ref.read(sessionProvider.notifier);
    final session = ref.read(sessionProvider);
    _shownVersion = session.telemetryVersion;
    final latest = session.latest;
    final samples = controller.telemetry.samples.toList(growable: false);

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: [
        if (widget.showHandle)
          const _Handle()
        else
          const SizedBox(height: AppSpace.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                'Measurements',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Text(
              settings.mode.label,
              style: AppType.caption.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        // Current measurements and the theory check lead the panel, so they
        // fit at the sheet's starting height; setup and visibility follow.
        _Readouts(
          mode: settings.mode,
          slidingBody: settings.slidingBody,
          state: latest,
        ),
        const SizedBox(height: AppSpace.md),
        _TheoryCard(
          check: theoryCheck(
            mode: settings.mode,
            slidingBody: settings.slidingBody,
            latest: latest?.tracked == true ? latest : null,
            samples: samples,
          ),
        ),
        if (settings.mode == ExperimentMode.ramp) ...[
          const SizedBox(height: AppSpace.md),
          _BodyPicker(sliding: settings.slidingBody),
        ],
        const SizedBox(height: AppSpace.xl),
        const Divider(),
        const SizedBox(height: AppSpace.lg),
        Text('Camera overlays', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.md),
        _LayerToggles(settings: settings),
        const SizedBox(height: AppSpace.xl),
        const Divider(),
        const SizedBox(height: AppSpace.lg),
        _QuantityPicker(
          value: _quantity,
          onChanged: (q) => setState(() => _quantity = q),
        ),
        const SizedBox(height: AppSpace.md),
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.graphiteDeep,
            border: Border.all(color: AppColors.ruleDark),
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.md,
                  AppSpace.md,
                  AppSpace.md,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_quantity.label} over time',
                        style: AppType.label.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Text(
                      'Last ${AppConfig.telemetryWindow.inSeconds} s',
                      style: AppType.readoutSmall.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 168,
                child: TelemetryChart(samples: samples, quantity: _quantity),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.md,
                  0,
                  AppSpace.md,
                  AppSpace.md,
                ),
                child: _ChartLegend(quantity: _quantity),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        const Divider(),
        const SizedBox(height: AppSpace.lg),
        Text('Energy', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.md),
        EnergyBars(energy: latest?.tracked == true ? latest?.energy : null),
        const SizedBox(height: AppSpace.xl),
        // For when tracking goes wrong mid-experiment; out of the way of
        // the physics, so it lives at the end.
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => copyDebugLog(context),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            icon: const Icon(AppIcons.copy, size: 18),
            label: const Text('Copy debug log'),
          ),
        ),
      ],
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.sm, bottom: AppSpace.md),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outline,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// Three pills that show or hide each family of arrows. Each carries its
/// quantity's colour and symbol, so it doubles as the overlay's legend.
class _LayerToggles extends ConsumerWidget {
  const _LayerToggles({required this.settings});

  final ExperimentSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(experimentSettingsProvider.notifier);
    return Row(
      children: [
        Expanded(
          child: _LayerToggle(
            symbol: 'v',
            label: 'Velocity',
            color: AppColors.velocity,
            on: settings.showVelocity,
            onTap: c.toggleVelocity,
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: _LayerToggle(
            symbol: 'a',
            label: 'Acceleration',
            color: AppColors.acceleration,
            on: settings.showAcceleration,
            onTap: c.toggleAcceleration,
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: _LayerToggle(
            symbol: 'F',
            label: 'Forces',
            color: AppColors.forceNet,
            on: settings.showForces,
            onTap: c.toggleForces,
          ),
        ),
      ],
    );
  }
}

class _LayerToggle extends StatelessWidget {
  const _LayerToggle({
    required this.symbol,
    required this.label,
    required this.color,
    required this.on,
    required this.onTap,
  });

  final String symbol;
  final String label;
  final Color color;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = on ? scheme.onSurface : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      toggled: on,
      label: '$label arrows',
      excludeSemantics: true,
      child: Material(
        color: on ? color.withValues(alpha: 0.16) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(6)),
          side: BorderSide(
            color: on ? color.withValues(alpha: 0.7) : scheme.outline,
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedOpacity(
            duration: AppMotion.quick,
            opacity: on ? 1 : 0.7,
            child: SizedBox(
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  PhysicsSymbol(
                    symbol,
                    color: on ? color : scheme.onSurfaceVariant,
                    size: 17,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: AppType.label.copyWith(color: ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Big live numbers: speed and acceleration magnitude, plus whatever the
/// current experiment adds (ramp angle and friction, swing angle and
/// length, momentum and bounciness).
class _Readouts extends StatelessWidget {
  const _Readouts({
    required this.mode,
    required this.slidingBody,
    required this.state,
  });

  final ExperimentMode mode;
  final bool slidingBody;
  final PhysicsState? state;

  @override
  Widget build(BuildContext context) {
    final s = state?.tracked == true ? state : null;
    final extras = s?.extras ?? const {};
    double? extra(String key) => extras[key];

    final items = <Widget>[
      _Readout(
        symbol: 'v',
        color: AppColors.velocity,
        spoken: 'Speed',
        value: s?.velocity?.length,
        unit: 'm/s',
        spokenUnit: 'metres per second',
      ),
      _Readout(
        symbol: 'a',
        color: AppColors.acceleration,
        spoken: 'Acceleration',
        value: s?.acceleration?.length,
        unit: 'm/s²',
        spokenUnit: 'metres per second squared',
      ),
      if (mode == ExperimentMode.ramp)
        _Readout(
          symbol: 'θ',
          spoken: 'Ramp angle',
          value: extra('angle_deg'),
          unit: '°',
          spokenUnit: 'degrees',
          decimals: 1,
        ),
      // Only a sliding block has a friction coefficient to measure.
      if (mode == ExperimentMode.ramp && slidingBody)
        _Readout(
          symbol: 'μ',
          spoken: 'Friction coefficient',
          value: extra('mu'),
          unit: '',
          spokenUnit: '',
        ),
      if (mode == ExperimentMode.pendulum) ...[
        _Readout(
          symbol: 'θ',
          spoken: 'Swing angle',
          value: extra('theta_deg'),
          unit: '°',
          spokenUnit: 'degrees',
          decimals: 1,
          signed: true,
        ),
        _Readout(
          symbol: 'L',
          spoken: 'String length',
          value: extra('length_m'),
          unit: 'm',
          spokenUnit: 'metres',
        ),
      ],
      if (mode == ExperimentMode.collision) ...[
        _Readout(
          symbol: 'p',
          spoken: 'Momentum',
          value: _magnitude(extra('momentum_x'), extra('momentum_y')),
          unit: 'kg m/s',
          spokenUnit: 'kilogram metres per second',
          decimals: 3,
        ),
        _Readout(
          symbol: 'e',
          spoken: 'Restitution',
          value: extra('restitution'),
          unit: '',
          spokenUnit: '',
        ),
      ],
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Two columns keep the quantity names and instrument values readable.
        final perRow = constraints.maxWidth < 280 ? 1 : 2;
        final width =
            (constraints.maxWidth - AppSpace.md * (perRow - 1)) / perRow;
        return Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.md,
          children: [
            for (final item in items) SizedBox(width: width, child: item),
          ],
        );
      },
    );
  }
}

double? _magnitude(double? x, double? y) =>
    x == null || y == null ? null : math.sqrt(x * x + y * y);

class _Readout extends StatelessWidget {
  const _Readout({
    required this.symbol,
    required this.spoken,
    required this.value,
    required this.unit,
    required this.spokenUnit,
    this.color,
    this.decimals = 2,
    this.signed = false,
  });

  final String symbol;
  final Color? color;
  final String spoken;
  final double? value;
  final String unit;
  final String spokenUnit;
  final int decimals;

  /// Show a sign (a swing angle is left or right of straight down).
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = value;
    final text = v == null
        ? 'n/a'
        : (signed ? v : v.abs())
              .toStringAsFixed(decimals)
              .replaceFirst('-', '−');

    return Semantics(
      label: v == null ? '$spoken not available' : '$spoken $text $spokenUnit',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.md,
          AppSpace.md,
          AppSpace.sm,
          AppSpace.md,
        ),
        decoration: BoxDecoration(
          // The quantity color identifies the value; the recessed neutral
          // surface keeps the number readable against the telemetry sheet.
          color: AppColors.graphiteDeep,
          border: Border(
            left: BorderSide(color: color ?? scheme.outline, width: 2),
            bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.65)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                PhysicsSymbol(
                  symbol,
                  color: color ?? scheme.onSurface,
                  size: 17,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    spoken,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.caption.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 6,
              children: [
                Text(
                  text,
                  style: AppType.readout.copyWith(
                    color: v == null
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                  ),
                ),
                if (unit.isNotEmpty)
                  Text(
                    unit,
                    style: AppType.readoutSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Rolling ball or sliding block: they need different models on the ramp.
class _BodyPicker extends ConsumerWidget {
  const _BodyPicker({required this.sliding});

  final bool sliding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(experimentSettingsProvider.notifier);
    return Row(
      children: [
        Expanded(
          child: _Choice(
            label: 'Rolling ball',
            selected: !sliding,
            onTap: () => c.setSlidingBody(false),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: _Choice(
            label: 'Sliding block',
            selected: sliding,
            onTap: () => c.setSlidingBody(true),
          ),
        ),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: selected
            ? scheme.onSurface.withValues(alpha: 0.1)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(6)),
          side: BorderSide(
            color: selected ? scheme.onSurface : scheme.outline,
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: AppType.label.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Measured against predicted, so a run can confirm or bust the textbook.
class _TheoryCard extends StatelessWidget {
  const _TheoryCard({required this.check});

  final TheoryCheck check;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final caption = AppType.caption.copyWith(color: scheme.onSurfaceVariant);
    final decimals = check.symbol == 'p' ? 3 : 2;
    String number(double? v) =>
        v == null ? 'n/a' : v.toStringAsFixed(decimals).replaceFirst('-', '−');
    final measured = number(check.measured);
    final predicted = number(check.predicted);
    final off = check.percentOff;
    final verdict = off == null
        ? check.waitingFor
        : off <= 10
        ? 'Within ${off.toStringAsFixed(0)}% of the prediction.'
        : '${off.toStringAsFixed(0)}% away from the prediction.';

    // Side by side, so the whole card fits at the sheet's starting height.
    // On a narrow phone the pair wraps instead of cutting a value short.
    Widget pair(String label, String value) => Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: caption),
        const SizedBox(width: AppSpace.sm),
        Text(
          value,
          style: AppType.readoutSmall.copyWith(color: scheme.onSurface),
        ),
        const SizedBox(width: AppSpace.xs),
        Text(check.unit, style: caption),
      ],
    );

    return Semantics(
      label:
          'Theory check, ${check.quantity}. Measured $measured, '
          'predicted $predicted ${check.spokenUnit}. $verdict',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: AppColors.graphiteDeep,
          border: Border.all(color: scheme.outline.withValues(alpha: 0.65)),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Theory check',
                    style: AppType.label.copyWith(color: scheme.onSurface),
                  ),
                ),
                Flexible(
                  child: Text(
                    check.model,
                    textAlign: TextAlign.end,
                    style: AppType.variable.copyWith(
                      fontSize: 15,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(check.quantity, style: caption),
            const SizedBox(height: AppSpace.xs),
            Wrap(
              spacing: AppSpace.xl,
              runSpacing: AppSpace.xs,
              children: [
                pair('Measured', measured),
                pair('Predicted', predicted),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              verdict,
              style: AppType.caption.copyWith(color: scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuantityPicker extends StatelessWidget {
  const _QuantityPicker({required this.value, required this.onChanged});

  final ChartQuantity value;
  final ValueChanged<ChartQuantity> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Match the selected control to the plotted series without using physics
    // colors for unrelated interface chrome.
    final quantityColor = switch (value) {
      ChartQuantity.position => scheme.onSurface,
      ChartQuantity.velocity => AppColors.velocity,
      ChartQuantity.acceleration => AppColors.acceleration,
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final q in ChartQuantity.values) ...[
            Semantics(
              button: true,
              selected: q == value,
              label: 'Chart ${q.label.toLowerCase()}',
              excludeSemantics: true,
              child: Material(
                color: q == value
                    ? quantityColor.withValues(alpha: 0.15)
                    : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                  side: BorderSide(
                    color: q == value ? quantityColor : scheme.outline,
                    width: 1.5,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onChanged(q),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                      vertical: 10,
                    ),
                    child: Text(
                      q.label,
                      style: AppType.label.copyWith(color: scheme.onSurface),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpace.sm),
          ],
        ],
      ),
    );
  }
}

/// "x solid, y dashed", drawn with the same strokes as the chart.
class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.quantity});

  final ChartQuantity quantity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (quantity) {
      ChartQuantity.position => scheme.onSurface,
      ChartQuantity.velocity => AppColors.velocity,
      ChartQuantity.acceleration => AppColors.acceleration,
    };
    final caption = AppType.caption.copyWith(color: scheme.onSurfaceVariant);

    Widget entry(String axis, {required bool dashed}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(22, 10),
          painter: _StrokeSample(color: color, dashed: dashed),
        ),
        const SizedBox(width: 6),
        PhysicsSymbol(axis, size: 14, color: scheme.onSurface),
        const SizedBox(width: 4),
        Text(dashed ? 'vertical' : 'horizontal', style: caption),
      ],
    );

    return ExcludeSemantics(
      child: Wrap(
        spacing: AppSpace.lg,
        runSpacing: AppSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          entry('x', dashed: false),
          entry('y', dashed: true),
          Text('in ${quantity.unit}', style: caption),
        ],
      ),
    );
  }
}

class _StrokeSample extends CustomPainter {
  const _StrokeSample({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = dashed ? 1.8 : 2.4;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    for (var x = 0.0; x < size.width; x += 9) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + 5).clamp(0, size.width), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StrokeSample old) =>
      old.color != color || old.dashed != dashed;
}
