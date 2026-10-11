import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../network/capture_export.dart';

const supported = true;

void downloadCapture(CaptureExport file) {
  final blob = web.Blob(
    [file.bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = file.filename;
  try {
    web.document.body!.appendChild(anchor);
    anchor.click();
  } finally {
    anchor.remove();
    // Allow browsers to start consuming the blob before releasing its URL.
    Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
  }
}
