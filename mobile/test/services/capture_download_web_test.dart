@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/services/download/capture_download_web.dart';
import 'package:hands_on_physics/services/network/capture_export.dart';
import 'package:web/web.dart' as web;

void main() {
  test(
    'download click carries the filename and exact UTF-8 blob bytes',
    () async {
      String? url, filename;
      final listener = ((web.Event event) {
        if (event.target case final web.HTMLAnchorElement anchor) {
          event.preventDefault();
          url = anchor.href;
          filename = anchor.download;
          expect(anchor.isConnected, true);
        }
      }).toJS;
      web.document.addEventListener('click', listener);
      addTearDown(() => web.document.removeEventListener('click', listener));
      final body = jsonEncode({
        'format': 'hands-on-physics-capture',
        'ruler': .3,
      });
      downloadCapture(
        CaptureExport('test.hop.json', Uint8List.fromList(utf8.encode(body))),
      );
      expect(filename, 'test.hop.json');
      expect(url, startsWith('blob:'));
      final response = await web.window.fetch(url!.toJS).toDart;
      expect(await response.text().toDart, body);
      expect(response.headers.get('Content-Type'), 'application/json');
      expect(web.document.querySelector('a[download="test.hop.json"]'), isNull);
    },
  );
}
