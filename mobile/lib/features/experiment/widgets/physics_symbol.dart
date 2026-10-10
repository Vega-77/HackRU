import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';

/// A physics variable as a textbook prints it: an italic symbol with an
/// optional upright subscript, such as *F*<sub>N</sub> or *U*<sub>g</sub>.
///
/// The same symbols label the arrows on the overlay, so a student can match
/// a readout to its arrow by shape as well as colour.
class PhysicsSymbol extends StatelessWidget {
  const PhysicsSymbol(
    this.symbol, {
    super.key,
    this.subscript = '',
    this.color,
    this.size = 16,
  });

  final String symbol;
  final String subscript;

  /// Defaults to the surrounding text colour.
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? DefaultTextStyle.of(context).style.color;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: symbol,
            style: AppType.variable.copyWith(fontSize: size, color: ink),
          ),
          if (subscript.isNotEmpty)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Transform.translate(
                offset: Offset(1, size * 0.28),
                child: Text(
                  subscript,
                  style: AppType.label.copyWith(
                    fontSize: size * 0.66,
                    color: ink,
                  ),
                ),
              ),
            ),
        ],
      ),
      // Read by screen readers from the parent's semantics label instead.
      semanticsLabel: '',
    );
  }
}
