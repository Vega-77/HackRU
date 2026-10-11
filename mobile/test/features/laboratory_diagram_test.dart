import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/home/widgets/laboratory_diagram.dart';

void main() {
  test('arrows keep their desktop length on a small diagram', () {
    const phone = 257.0;
    expect(
      LaboratoryDiagram.vectorScale(phone),
      LaboratoryDiagram.minVectorScale,
    );
  });

  test('arrows grow with a diagram larger than the floor', () {
    const wide = LaboratoryDiagram.minVectorScale + 100;
    expect(LaboratoryDiagram.vectorScale(wide), wide);
  });
}
