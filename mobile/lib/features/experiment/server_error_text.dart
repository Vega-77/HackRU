import '../../models/physics_state.dart';

/// The banner text for a backend error: what failed, where in the backend,
/// how often, and which backend build said so. With all of it on screen, a
/// screenshot is enough to find the bug.
String describeServerError(ErrorMessage error, {int count = 1}) {
  final message = error.message.trim();
  return [
    'The backend reported: $message${message.endsWith('.') ? '' : '.'}',
    if (error.where != null) 'In ${error.where}.',
    if (count > 1) 'Same error on $count frames in a row.',
    if (error.serverVersion != null) 'Backend version ${error.serverVersion}.',
  ].join(' ');
}
