import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/physics_state.dart';
import 'physics_symbol.dart';

/// The energy audit: kinetic, gravitational potential and thermal energy as
/// one stacked bar, so you can watch energy move between them while the
/// total stays (nearly) the same.
class EnergyBars extends StatelessWidget {
  const EnergyBars({super.key, required this.energy});

  final EnergyState? energy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = energy;
    final parts = [
      _Part('K', '', 'Kinetic', AppColors.kinetic, e?.kinetic),
      _Part('U', 'g', 'Potential', AppColors.potential, e?.potential),
      _Part('E', 'th', 'Thermal', AppColors.thermal, e?.thermal),
    ];
    final total = parts.fold<double>(
      0,
      (sum, p) => sum + (p.value ?? 0).clamp(0, double.infinity),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: e == null
              ? 'Energy not available yet'
              : [
                  for (final p in parts)
                    if (p.value != null)
                      '${p.name} ${_joules(p.value!)} joules',
                ].join(', '),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(6)),
            child: SizedBox(
              height: 14,
              child: total <= 0
                  ? ColoredBox(color: scheme.outline)
                  : Row(
                      children: [
                        for (final p in parts)
                          if ((p.value ?? 0) > 0)
                            Expanded(
                              flex: ((p.value! / total) * 1000).round().clamp(
                                1,
                                1000,
                              ),
                              child: ColoredBox(color: p.color),
                            ),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        ExcludeSemantics(
          child: Row(
            children: [
              for (final p in parts) Expanded(child: _Legend(part: p)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Three significant figures, in joules.
String _joules(double value) {
  final v = value.abs();
  if (v == 0) return '0';
  if (v >= 100) return value.toStringAsFixed(0);
  if (v >= 10) return value.toStringAsFixed(1);
  if (v >= 1) return value.toStringAsFixed(2);
  return value.toStringAsPrecision(3);
}

class _Part {
  const _Part(this.symbol, this.subscript, this.name, this.color, this.value);

  final String symbol;
  final String subscript;
  final String name;
  final Color color;
  final double? value;
}

class _Legend extends StatelessWidget {
  const _Legend({required this.part});

  final _Part part;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: part.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            PhysicsSymbol(part.symbol, subscript: part.subscript, size: 15),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                part.name,
                overflow: TextOverflow.ellipsis,
                style: AppType.caption.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: part.value == null ? 'n/a' : _joules(part.value!),
                style: AppType.readoutSmall.copyWith(
                  fontSize: 15,
                  color: scheme.onSurface,
                ),
              ),
              if (part.value != null)
                TextSpan(
                  text: ' J',
                  style: AppType.readoutSmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
