import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/experiment/experiment_screen.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/network/recorded_analysis.dart';
import 'package:hands_on_physics/services/network/capture_export.dart';
import 'package:hands_on_physics/services/download/capture_download.dart';
import 'package:hands_on_physics/state/session_controller.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';

class FreeFallSettings extends ExperimentSettingsController {
  @override
  ExperimentSettings build() =>
      const ExperimentSettings(mode: ExperimentMode.freeFall);
}

class RecordingSession extends SessionController {
  RecordingSession(this.initial);
  final RecordingPhase initial;
  var recorded = 0, retried = 0, cancelled = 0;
  @override
  SessionState build() => SessionState(
    phase: SessionPhase.paused,
    recordingPhase: initial,
    recordingProgress: .4,
    recordingMessage:
        'Saved recording. Retry analysis when the connection returns.',
    latest: const PhysicsState(frameId: 0, t: 1, tracked: false),
    recordedLatest: const PhysicsState(
      frameId: 2,
      t: 2,
      tracked: true,
      position: Vec2(1, 1),
    ),
  );
  @override
  Future<void> start() async {}
  @override
  Future<void> stop({int? onlyIfEpoch}) async {}
  @override
  bool get canRetryRecordedAnalysis => true;
  @override
  bool get canExportRecording =>
      initial == RecordingPhase.complete || initial == RecordingPhase.failed;
  @override
  CaptureExport exportRecording() =>
      CaptureExport('test.hop.json', Uint8List.fromList([1, 2, 3]));
  @override
  Future<void> recordFreeFall() async {
    recorded++;
    state = state.copyWith(recordingPhase: RecordingPhase.recording);
  }

  @override
  Future<void> retryRecordedAnalysis() async {
    retried++;
    state = state.copyWith(recordingPhase: RecordingPhase.analyzing);
  }

  @override
  void cancelRecording() {
    cancelled++;
    state = state.copyWith(recordingPhase: RecordingPhase.idle);
  }
}

void main() {
  testWidgets(
    'download failure reports an error and leaves the capture available',
    (tester) async {
      final controller = RecordingSession(RecordingPhase.failed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(() => controller),
            experimentSettingsProvider.overrideWith(FreeFallSettings.new),
            captureDownloaderProvider.overrideWithValue(
              (_) => throw StateError('browser download unavailable'),
            ),
          ],
          child: const MaterialApp(home: ExperimentScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Download capture'));
      await tester.pump();
      expect(
        find.text('Could not download the capture. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Download capture'), findsOneWidget);
      expect(controller.canExportRecording, true);
      expect(controller.retried, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );
  for (final size in [const Size(390, 844), const Size(1366, 768)]) {
    for (final phase in RecordingPhase.values) {
      testWidgets('recording $phase fits $size and actions work', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = RecordingSession(phase);
        CaptureExport? downloaded;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sessionProvider.overrideWith(() => controller),
              experimentSettingsProvider.overrideWith(FreeFallSettings.new),
              captureDownloaderProvider.overrideWithValue(
                (file) => downloaded = file,
              ),
            ],
            child: const MaterialApp(home: ExperimentScreen()),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        if (phase == RecordingPhase.complete ||
            phase == RecordingPhase.failed) {
          await tester.tap(find.text('Download capture'));
          expect(downloaded!.filename, 'test.hop.json');
          expect(downloaded!.bytes, [1, 2, 3]);
          await tester.pump();
          expect(find.textContaining('Find the capture'), findsOneWidget);
        } else {
          expect(find.text('Download capture'), findsNothing);
        }
        if (phase == RecordingPhase.recording ||
            phase == RecordingPhase.analyzing) {
          await tester.tap(find.text('Cancel'));
          expect(controller.cancelled, 1);
        } else if (phase == RecordingPhase.failed) {
          await tester.tap(find.text('Retry analysis'));
          expect(controller.retried, 1);
        } else {
          await tester.tap(find.text('Record 3 s'));
          expect(controller.recorded, 1);
        }
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }
}
