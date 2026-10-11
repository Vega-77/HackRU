import 'package:flutter/material.dart';

/// One run of a formula: plain text, or a subscript.
typedef FormulaPart = ({String text, bool subscript});

/// Splits a formula written as `F_{net} = ma` or `a_y = −g` into runs.
///
/// Archivo has no Unicode subscript letters, so subscripts are drawn as
/// smaller, lowered text instead. `_x` lowers one character and `_{xy}`
/// lowers everything up to the closing brace.
List<FormulaPart> formulaParts(String formula) {
  final parts = <FormulaPart>[];
  final plain = StringBuffer();
  void flush() {
    if (plain.isEmpty) return;
    parts.add((text: plain.toString(), subscript: false));
    plain.clear();
  }

  var i = 0;
  while (i < formula.length) {
    final c = formula[i];
    if (c == '_' && i + 1 < formula.length) {
      flush();
      if (formula[i + 1] == '{') {
        final end = formula.indexOf('}', i + 2);
        final close = end == -1 ? formula.length : end;
        parts.add((text: formula.substring(i + 2, close), subscript: true));
        i = close + 1;
      } else {
        parts.add((text: formula[i + 1], subscript: true));
        i += 2;
      }
      continue;
    }
    plain.write(c);
    i++;
  }
  flush();
  return parts;
}

/// The formula as a screen reader should hear it, without the markup.
String formulaSpoken(String formula) =>
    formulaParts(formula)
        .map((p) => p.subscript ? ' ${p.text} ' : p.text)
        .join()
        .replaceAll(RegExp(' +'), ' ')
        .trim();

/// Draws a formula with its subscripts lowered, in [style].
class Formula extends StatelessWidget {
  const Formula(this.formula, {super.key, required this.style});

  final String formula;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final size = style.fontSize ?? 16;
    return Semantics(
      label: formulaSpoken(formula),
      child: ExcludeSemantics(
        child: Text.rich(
          TextSpan(
            style: style,
            children: [
              for (final part in formulaParts(formula))
                if (part.subscript)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: Transform.translate(
                      offset: Offset(0, size * 0.28),
                      child: Text(
                        part.text,
                        style: style.copyWith(fontSize: size * 0.66),
                      ),
                    ),
                  )
                else
                  TextSpan(text: part.text),
            ],
          ),
        ),
      ),
    );
  }
}
