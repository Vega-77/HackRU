import 'frame_source.dart';

/// Fallback for platforms with neither dart:io nor JS interop. Never used
/// in practice; it exists so the conditional import always resolves.
FrameSource createPlatformFrameSource() =>
    throw UnsupportedError('No camera implementation for this platform.');
