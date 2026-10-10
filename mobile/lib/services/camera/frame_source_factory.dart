// Picks the right FrameSource for the platform at compile time.
//
// The web build imports web_frame_source.dart (package:web, dart:ui_web);
// the iOS build imports native_frame_source.dart (camera plugin, isolates).
// Neither file is ever compiled for the other platform.
import 'frame_source.dart';
import 'frame_source_stub.dart'
    if (dart.library.js_interop) 'web_frame_source.dart'
    if (dart.library.io) 'native_frame_source.dart';

export 'frame_source.dart';

FrameSource createFrameSource() => createPlatformFrameSource();
