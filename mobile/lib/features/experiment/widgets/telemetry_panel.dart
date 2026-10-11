import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/tokens.dart';
import '../../../models/experiment_mode.dart';
import '../../../models/physics_state.dart';
import '../../../state/experiment_settings.dart';
import '../../../state/session_controller.dart';
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
        _LayerToggles(settings: settings),
        const SizedBox(height: AppSpace.xl),
        _Readouts(mode: settings.mode, state: latest),
        const SizedBox(height: AppSpace.xl),
        const Divider(),
        const SizedBox(height: AppSpace.lg),
        _QuantityPicker(
          value: _quantity,
          onChanged: (q) => setState(() => _quantity = q),
        ),
        const SizedBox(height: AppSpace.md),
        SizedBox(
          height: 168,
          child: TelemetryChart(samples: samples, quantity: _quantity),
        ),
        const SizedBox(height: AppSpace.sm),
        _ChartLegend(quantity: _quantity),
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
        shape: StadiumBorder(
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
/// current experiment adds (ramp angle and friction, swing angle,
/// momentum).
class _Readouts extends StatelessWidget {
  const _Readouts({required this.mode, required this.state});

  final ExperimentMode mode;
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
      if (mode == ExperimentMode.ramp || mode == ExperimentMode.pendulum)
        _Readout(
          symbol: 'θ',
          spoken: 'Angle',
          value: extra('angle_deg'),
          unit: '°',
          spokenUnit: 'degrees',
          decimals: 1,
        ),
      if (mode == ExperimentMode.ramp)
        _Readout(
          symbol: 'μ',
          spoken: 'Friction coefficient',
          value: extra('mu'),
          unit: '',
          spokenUnit: '',
        ),
      if (mode == ExperimentMode.collision)
        _Readout(
          symbol: 'p',
          spoken: 'Momentum',
          value: extra('momentum'),
          unit: 'kg m/s',
          spokenUnit: 'kilogram metres per second',
          signed: true,
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Up to four across; wraps to a second row on narrow screens.
        final perRow = items.length <= 3
            ? items.length
            : (constraints.maxWidth > 340 ? 4 : 2);
        final width =
            (constraints.maxWidth - AppSpace.lg * (perRow - 1)) / perRow;
        return Wrap(
          spacing: AppSpace.lg,
          runSpacing: AppSpace.lg,
          children: [
            for (final item in items) SizedBox(width: width, child: item),
          ],
        );
      },
    );
  }
}

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

  /// Show a sign (momentum has a direction along the track).
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              PhysicsSymbol(symbol, color: color ?? scheme.onSurface, size: 17),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    unit,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.readoutSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              text,
              style: AppType.readout.copyWith(
                color: v == null ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ),
        ],
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
                color: q == value ? scheme.onSurface : Colors.transparent,
                shape: StadiumBorder(
                  side: BorderSide(
                    color: q == value ? scheme.onSurface : scheme.outline,
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
                      style: AppType.label.copyWith(
                        color: q == value ? scheme.surface : scheme.onSurface,
                      ),
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
