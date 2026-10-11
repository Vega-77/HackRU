@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/services/camera/web_frame_source.dart';

// Run Chrome with --use-fake-device-for-media-stream --use-fake-ui-for-media-stream.
void main() {
  test(
    'browser pixels retain a video-frame timestamp through repeated encoding',
    () async {
      final camera = WebFrameSource();
      addTearDown(camera.stop);
      await camera.start();
      final first = (await camera.capture())!;
      final same = (await camera.capture())!;
      expect(first.jpeg, isNotEmpty);
      expect(first.captureTime, same.captureTime);
      expect(first.jpeg, same.jpeg);
      expect(same.ageAtEncodingMs, greaterThanOrEqualTo(first.ageAtEncodingMs));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final next = (await camera.capture())!;
      expect(next.captureTime, greaterThan(first.captureTime));
      expect(next.size, first.size);
      expect(next.ageAtEncodingMs, lessThan(1000));
    },
  );
}
