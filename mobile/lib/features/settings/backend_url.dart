import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/network/physics_socket.dart';

/// The port and path `backend/serve_lan.py` serves on.
const _lanPort = 8000;
const _framesPath = '/ws/frames';

/// Fills in what a laptop address usually leaves out, so `192.168.1.20`
/// becomes `ws://192.168.1.20:8000/ws/frames`, and adds the path to a full
/// address that has none. Anything it can't read is returned trimmed, for
/// [validateBackendUrl] to explain.
String normalizeBackendUrl(String text) {
  final value = text.trim();
  final bare = !value.contains('://');
  final uri = Uri.tryParse(bare ? 'ws://$value' : value);
  if (value.isEmpty || uri == null || uri.host.isEmpty) return value;
  if (uri.scheme != 'ws' && uri.scheme != 'wss') return value;
  final noPath = uri.path.isEmpty || uri.path == '/';
  return uri
      .replace(
        port: bare && !uri.hasPort ? _lanPort : null,
        path: noPath ? _framesPath : null,
      )
      .toString();
}

/// Checks a backend address typed in Settings, after [normalizeBackendUrl].
///
/// Returns null when [text] is a usable WebSocket URL, otherwise a short
/// message saying what to fix. [page] is where the app itself is loaded
/// from, [Uri.base] by default.
String? validateBackendUrl(String text, {Uri? page}) {
  final value = text.trim();
  if (value.isEmpty) return 'Enter the backend address';
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) {
    return 'Start with ws://, for example ws://192.168.1.20:8000/ws/frames';
  }
  if (uri.scheme != 'ws' && uri.scheme != 'wss') {
    return 'Use ws:// or wss://, not ${uri.scheme}://';
  }
  if (uri.host.isEmpty) return 'Add the computer\'s address after ws://';
  if (_blockedAsMixedContent(uri, page ?? Uri.base)) {
    return 'This https page can only reach wss:// addresses. For a laptop '
        'backend, use the iPhone app.';
  }
  return null;
}

/// A browser blocks an https page from opening an unencrypted ws://
/// connection, except to the same computer.
bool _blockedAsMixedContent(Uri backend, Uri page) =>
    page.scheme == 'https' &&
    backend.scheme == 'ws' &&
    !const {'localhost', '127.0.0.1', '::1'}.contains(backend.host);

/// True for a backend on the internet (wss://), like the team's server on
/// Render, as opposed to a laptop on the same Wi-Fi (ws://).
///
/// A hosted free-tier server sleeps when nobody uses it and takes up to a
/// minute to wake, so the app waits longer for it.
bool isHostedBackend(String url) => Uri.tryParse(url.trim())?.scheme == 'wss';

/// Connects to [url] once, for "Test connection", and returns how long it
/// took to get through. A hosted backend gets retried until [wakeTimeout],
/// to give a sleeping server time to wake. Throws if it never answered.
Future<Duration> testBackend(
  String url, {
  Duration wakeTimeout = const Duration(seconds: 90),
  Duration retryDelay = const Duration(seconds: 2),
  Future<Duration> Function(String url, Duration timeout) probe = _probe,
}) async {
  if (!isHostedBackend(url)) return probe(url, const Duration(seconds: 3));
  final waited = Stopwatch()..start();
  while (true) {
    final left = wakeTimeout - waited.elapsed;
    try {
      await probe(url, left);
      return waited.elapsed;
    } catch (_) {
      if (waited.elapsed + retryDelay >= wakeTimeout) rethrow;
      await Future<void>.delayed(retryDelay);
    }
  }
}

Future<Duration> _probe(String url, Duration timeout) =>
    PhysicsSocket.probe(url, timeout: timeout);

/// What "Test connection" runs. Widget tests swap in a fake so they never
/// touch the network.
final backendTestProvider = Provider<Future<Duration> Function(String url)>(
  (ref) => testBackend,
);
