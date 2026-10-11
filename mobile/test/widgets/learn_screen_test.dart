import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/learn/learn_screen.dart';
import 'package:hands_on_physics/features/learn/lesson.dart';

void main() {
  for (final size in const [Size(320, 568), Size(1440, 1000)]) {
    testWidgets('every lesson fits $size', (tester) async {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      for (final lesson in Lesson.all) {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: LearnScreen(key: ValueKey(lesson.id), lessonId: lesson.id),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: lesson.title);
        expect(find.text(lesson.title), findsWidgets);
        expect(find.text('Common mistakes'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
