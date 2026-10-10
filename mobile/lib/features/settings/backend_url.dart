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
