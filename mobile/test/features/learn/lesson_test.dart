import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/learn/formula.dart';
import 'package:hands_on_physics/features/learn/lesson.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';

void main() {
  test('every experiment has a lesson, after the basics', () {
    expect(Lesson.all.first.id, Lesson.basicsId);
    expect(Lesson.all.first.mode, isNull);
    for (final mode in ExperimentMode.values) {
      expect(Lesson.forMode(mode).mode, mode);
    }
    expect(Lesson.all.map((l) => l.id).toSet(), hasLength(Lesson.all.length));
  });

  test('lessons chain in order and unknown ids fall back to the basics', () {
    expect(
      Lesson.byId('pendulum').next,
      Lesson.forMode(ExperimentMode.collision),
    );
    expect(Lesson.all.last.next, isNull);
    expect(Lesson.byId('nope').id, Lesson.basicsId);
  });

  test('every lesson covers arrows, forces, equations and mistakes', () {
    for (final lesson in Lesson.all) {
      expect(
        lesson.arrows.map((a) => a.kind).toSet(),
        VectorKind.values.toSet(),
        reason: lesson.title,
      );
      expect(lesson.forces, isNotEmpty, reason: lesson.title);
      expect(lesson.equations, isNotEmpty, reason: lesson.title);
      expect(lesson.mistakes, isNotEmpty, reason: lesson.title);
      if (lesson.mode != null) {
        expect(lesson.steps, isNotEmpty, reason: lesson.title);
        expect(lesson.equipment, isNotEmpty, reason: lesson.title);
      }
    }
  });

  test('lesson copy follows the style rules', () {
    for (final lesson in Lesson.all) {
      for (final text in lesson.copy) {
        expect(text, isNot(contains('—')), reason: text);
        expect(text, isNot(contains('·')), reason: text);
        expect(text, isNot(contains('!')), reason: text);
        expect(text.trim(), text, reason: 'stray spaces in "$text"');
        expect(text, isNot(contains('  ')), reason: 'double space in "$text"');
      }
    }
  });

  test('formulas lower single characters and braced runs', () {
    expect(formulaParts('a_y = −g'), [
      (text: 'a', subscript: false),
      (text: 'y', subscript: true),
      (text: ' = −g', subscript: false),
    ]);
    expect(formulaParts('F_{net} = ma'), [
      (text: 'F', subscript: false),
      (text: 'net', subscript: true),
      (text: ' = ma', subscript: false),
    ]);
    expect(formulaParts('p = mv'), [(text: 'p = mv', subscript: false)]);
    expect(formulaSpoken('v_{0y} − gt'), 'v 0y − gt');
  });
}
