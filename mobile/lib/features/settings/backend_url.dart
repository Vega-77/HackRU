import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/network/physics_socket.dart';

/// Checks a backend address typed in Settings.
///
/// Returns null when [text] is a usable WebSocket URL, otherwise a short
/// message saying what to fix.
String? validateBackendUrl(String text) {
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
  return null;
}

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
