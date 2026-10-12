import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/capture_export.dart';
import 'capture_download_stub.dart'
    if (dart.library.js_interop) 'capture_download_web.dart'
    as platform;

typedef CaptureDownloader = void Function(CaptureExport file);

final captureDownloaderProvider = Provider<CaptureDownloader?>(
  (ref) => platform.supported ? platform.downloadCapture : null,
);
