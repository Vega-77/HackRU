import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/home/home_screen.dart';
import 'package:hands_on_physics/features/home/widgets/laboratory_diagram.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';

void main() {
  Future<ProviderContainer> open(
    WidgetTester tester,
    Size size, {
    bool reduced = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduced,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
  }

  LaboratoryDiagram diagram(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((widget) => widget.painter)
      .whereType<LaboratoryDiagram>()
      .last;
  Future<void> close(WidgetTester tester) async =>
      tester.pumpWidget(const SizedBox());

  for (final size in [
    const Size(1440, 1000),
    const Size(960, 800),
    const Size(390, 844),
    const Size(320, 568),
    const Size(844, 390),
  ]) {
    testWidgets('laboratory fits $size and selects every investigation', (
      tester,
    ) async {
      final container = await open(tester, size, reduced: true);
      for (final mode in ExperimentMode.values) {
        final row = find.byKey(ValueKey('select-${mode.name}'));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pump();
        expect(container.read(experimentSettingsProvider).mode, mode);
        expect(diagram(tester).mode, mode);
        expect(diagram(tester).state.position, isNotNull);
        expect(find.text('Set up ${mode.label.toLowerCase()}'), findsOneWidget);
        await tester.ensureVisible(find.text('Force vectors'));
        await tester.tap(find.text('Force vectors'));
        await tester.pump();
        expect(diagram(tester).forces, true);
        await tester.ensureVisible(find.text('Motion vectors'));
        await tester.tap(find.text('Motion vectors'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await close(tester);
    });
  }
  testWidgets('pause preserves model phase and resume advances it', (
    tester,
  ) async {
    await open(tester, const Size(1440, 1000));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(find.byTooltip('Pause model'));
    await tester.pump();
    final paused = diagram(tester).state;
    await tester.pump(const Duration(seconds: 1));
    expect(diagram(tester).state.t, paused.t);
    expect(diagram(tester).state.position, paused.position);
    await tester.tap(find.byTooltip('Play model'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(diagram(tester).state.t, closeTo(paused.t + .1, .01));
    await tester.tap(find.byTooltip('Replay model'));
    await tester.pump();
    expect(diagram(tester).state.t, closeTo(0, .02));
    await close(tester);
  });
  testWidgets('reduced motion freezes model; vector views remain interactive', (
    tester,
  ) async {
    await open(tester, const Size(390, 844), reduced: true);
    final state = diagram(tester).state;
    await tester.pump(const Duration(seconds: 3));
    expect(diagram(tester).state.t, state.t);
    await tester.ensureVisible(find.text('Force vectors'));
    await tester.tap(find.text('Force vectors'));
    await tester.pump();
    expect(diagram(tester).forces, true);
    await tester.tap(find.text('Motion vectors'));
    await tester.pump();
    expect(diagram(tester).forces, false);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets('large text fits a small phone', (tester) async {
    await open(tester, const Size(320, 568), reduced: true, textScale: 1.6);
    await tester.ensureVisible(find.text('Force vectors'));
    await tester.tap(find.text('Force vectors'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets('investigations can be selected with keyboard', (tester) async {
    final container = await open(tester, const Size(1440, 1000), reduced: true);
    // Reading order includes model controls on desktop before the index.
    var reached = false;
    for (var i = 0; i < 20 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        element,
      ) {
        if (element.widget.key == const ValueKey('select-freeFall')) {
          reached = true;
          return false;
        }
        return true;
      });
    }
    expect(reached, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      container.read(experimentSettingsProvider).mode,
      ExperimentMode.freeFall,
    );
    await close(tester);
  });
}
