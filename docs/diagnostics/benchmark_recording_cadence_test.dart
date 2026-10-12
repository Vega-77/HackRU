import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/services/network/recorded_analysis.dart';
import 'package:hands_on_physics/services/network/recorded_analysis_baseline.dart' as baseline;
class Camera extends Fake implements FrameSource {
  final clock = Stopwatch()..start();
  @override bool get isRunning => true;
  @override Future<EncodedFrame?> capture({int width = 320}) async {
    final t = (clock.elapsedMicroseconds ~/ 16667) / 60;
    await Future<void>.delayed(const Duration(milliseconds:12));
    return EncodedFrame(jpeg:Uint8List.fromList([1,2,3]),size:const FrameSize(320,180),captureTime:t);
  }
}
void main() {
 test('cadence benchmark', () async {
   final metrics = <Map<String,dynamic>>[];
   for (var i=0;i<2;i++) {
    final before=await baseline.SequenceRecorder().collect(Camera(),duration:const Duration(seconds:1));
    final after=await SequenceRecorder().collect(Camera(),duration:const Duration(seconds:1));
    metrics.add({'before_frames':before.frames.length,'before_fps':before.fps,'before_max_gap_ms':before.maxGapMs,'after_frames':after.frames.length,'after_fps':after.fps,'after_max_gap_ms':after.maxGapMs});
   }
   print(jsonEncode(metrics));
 });
}
