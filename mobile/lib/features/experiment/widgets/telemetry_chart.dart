import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/tokens.dart';
import '../../../models/vec2.dart';
import '../../../state/telemetry_buffer.dart';

/// Which quantity the chart plots.
enum ChartQuantity {
  position('Position', 'm'),
  velocity('Velocity', 'm/s'),
  acceleration('Acceleration', 'm/s²');

  const ChartQuantity(this.label, this.unit);

  final String label;
  final String unit;

  Vec2? of(TelemetrySample s) => switch (this) {
    ChartQuantity.position => s.position,
    ChartQuantity.velocity => s.velocity,
    ChartQuantity.acceleration => s.acceleration,
  };
}

/// The last [AppConfig.telemetryWindow] of one quantity against time, with
/// the x component as a solid line and y as a dashed one.
///
/// Time runs from "10 s ago" on the left to "now" on the right, so the
/// newest point is always at the right edge, like a chart recorder.
class TelemetryChart extends StatelessWidget {
  const TelemetryChart({
    super.key,
    required this.samples,
    required this.quantity,
  });

  /// Oldest first.
  final List<TelemetrySample> samples;
  final ChartQuantity quantity;

  static double get _window => AppConfig.telemetryWindow.inMilliseconds / 1000;

  /// A gap this long between samples breaks the line instead of joining it.
  static const _gapS = 0.3;

  Color _lineColor(BuildContext context) => switch (quantity) {
    ChartQuantity.position => Theme.of(context).colorScheme.onSurface,
    ChartQuantity.velocity => AppColors.velocity,
    ChartQuantity.acceleration => AppColors.acceleration,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tickStyle = AppType.readoutSmall.copyWith(
      color: scheme.onSurfaceVariant,
      fontSize: 11,
    );

    if (samples.length < 2) {
      return Center(
        child: Text(
          'The chart fills in once the object is tracked.',
          style: AppType.caption.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }

    final now = samples.last.t;
    final xs = <FlSpot>[];
    final ys = <FlSpot>[];
    double? previousT;
    var lo = double.infinity, hi = -double.infinity;
    for (final s in samples) {
      final v = quantity.of(s);
      if (v == null) continue;
      if (previousT != null && s.t - previousT > _gapS) {
        xs.add(FlSpot.nullSpot);
        ys.add(FlSpot.nullSpot);
      }
      previousT = s.t;
      final t = s.t - now;
      xs.add(FlSpot(t, v.x));
      ys.add(FlSpot(t, v.y));
      lo = math.min(lo, math.min(v.x, v.y));
      hi = math.max(hi, math.max(v.x, v.y));
    }
    if (lo > hi) lo = hi = 0;
    final range = _NiceRange.around(lo, hi);
    final color = _lineColor(context);

    LineChartBarData line(List<FlSpot> spots, {required bool dashed}) =>
        LineChartBarData(
          spots: spots,
          color: color,
          barWidth: dashed ? 1.8 : 2.4,
          isCurved: false,
          dashArray: dashed ? const [5, 4] : null,
          dotData: const FlDotData(show: false),
        );

    return Semantics(
      label: '${quantity.label} over the last ${_window.round()} seconds',
      child: ExcludeSemantics(
        child: LineChart(
          duration: Duration.zero,
          LineChartData(
            minX: -_window,
            maxX: 0,
            minY: range.min,
            maxY: range.max,
            clipData: const FlClipData.all(),
            lineTouchData: const LineTouchData(enabled: false),
            borderData: FlBorderData(show: false),
            gridData: FlGridData(
              drawVerticalLine: true,
              verticalInterval: _window / 2,
              horizontalInterval: range.step,
              getDrawingHorizontalLine: (value) => FlLine(
                color: value == 0
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                    : scheme.outline,
                strokeWidth: 1,
              ),
              getDrawingVerticalLine: (_) =>
                  FlLine(color: scheme.outline, strokeWidth: 1),
            ),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  interval: range.step,
                  getTitlesWidget: (value, meta) {
                    // Skip the auto-added edge labels between ticks.
                    if (!_onTick(value, range.step)) return const SizedBox();
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(range.format(value), style: tickStyle),
                    );
                  },
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  interval: _window / 2,
                  getTitlesWidget: (value, meta) => SideTitleWidget(
                    meta: meta,
                    child: Text(
                      value == 0 ? 'now' : '${value.round()} s',
                      style: tickStyle,
                    ),
                  ),
                ),
              ),
            ),
            lineBarsData: [line(ys, dashed: true), line(xs, dashed: false)],
          ),
        ),
      ),
    );
  }

  static bool _onTick(double value, double step) {
    final k = value / step;
    return (k - k.round()).abs() < 1e-6;
  }
}

/// A y-axis range rounded out to 1, 2 or 5 × 10ⁿ steps, so tick labels are
/// round numbers and the axis does not jitter as data arrives.
class _NiceRange {
  const _NiceRange(this.min, this.max, this.step);

  factory _NiceRange.around(double lo, double hi) {
    var span = hi - lo;
    if (span < 1e-3) {
      // Flat line: give it a small window around the value.
      final pad = math.max(lo.abs() * 0.2, 0.05);
      lo -= pad;
      hi += pad;
      span = hi - lo;
    }
    final raw = span / 4;
    final magnitude = math
        .pow(10, (math.log(raw) / math.ln10).floor())
        .toDouble();
    final step = [
      1.0,
      2.0,
      5.0,
      10.0,
    ].map((m) => m * magnitude).firstWhere((s) => s >= raw);
    return _NiceRange(
      (lo / step).floor() * step,
      (hi / step).ceil() * step,
      step,
    );
  }

  final double min;
  final double max;
  final double step;

  String format(double value) {
    final decimals = step >= 1 ? 0 : (-(math.log(step) / math.ln10).floor());
    final text = value.toStringAsFixed(decimals.clamp(0, 3));
    // A true minus sign, and no "-0".
    if (double.parse(text) == 0) return '0';
    return text.replaceFirst('-', '−');
  }
}
