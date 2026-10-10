import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// The app's debug log. Every layer writes to it; Settings and the
/// experiment screen copy it to the clipboard so we can see what happened
/// on a phone. Users never see it on screen.
final log = DebugLog();

enum LogLevel {
  debug('D'),
  info('I'),
  warning('W'),
  error('E');

  const LogLevel(this.letter);
  final String letter;
}

class LogEntry {
  const LogEntry({
    required this.time,
    required this.elapsed,
    required this.level,
    required this.caller,
    required this.message,
    this.error,
    this.stack,
  });

  final DateTime time;

  /// Time since the current session started (or since launch, before one).
  final Duration elapsed;
  final LogLevel level;

  /// Where the entry was written, like
  /// `SessionController.start (state/session_controller.dart:150)`.
  final String caller;
  final String message;
  final Object? error;
  final StackTrace? stack;

  /// One line (plus indented error and stack lines), like
  /// `14:03:22.418 +12.345s I SessionController.start (...:150) message`.
  String format() {
    final buffer = StringBuffer()
      ..write(_clock(time))
      ..write(' +')
      ..write((elapsed.inMicroseconds / 1e6).toStringAsFixed(3))
      ..write('s ')
      ..write(level.letter)
      ..write(' ')
      ..write(caller)
      ..write(' ')
      ..write(message);
    if (error != null) buffer.write('\n    error: $error');
    final trace = stack?.toString().trimRight() ?? '';
    if (trace.isNotEmpty) {
      final lines = trace.split('\n');
      for (final line in lines.take(DebugLog.stackLines)) {
        buffer.write('\n    $line');
      }
      if (lines.length > DebugLog.stackLines) {
        buffer.write('\n    ... ${lines.length - DebugLog.stackLines} more');
      }
    }
    return buffer.toString();
  }

  static String _clock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }
}

class DebugLog {
  DebugLog({this.capacity = 20000});

  /// About eleven minutes of an experiment at 15 fps: a line per frame
  /// sent, one per reply, and a summary each second.
  final int capacity;

  static const stackLines = 20;

  /// Where each entry is echoed as it is written: the `flutter run` and
  /// Xcode console. It bypasses zones so main's print hook never sees it.
  /// Tests set it to null to keep their output quiet.
  void Function(String line)? echo = Zone.root.print;

  /// Extra lines for the top of [dump], like the backend URL and mode.
  /// The session sets it, so core never imports app state.
  Map<String, Object?> Function()? context;

  final _entries = ListQueue<LogEntry>();
  final _sinceSession = Stopwatch()..start();
  int _dropped = 0;

  int get entryCount => _entries.length;

  /// Entries pushed out because the log was full.
  int get dropped => _dropped;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Per-frame detail.
  void d(String message) => _add(LogLevel.debug, message);

  /// Something changed: a session started, the socket connected.
  void i(String message) => _add(LogLevel.info, message);

  void w(String message, [Object? error, StackTrace? stack]) =>
      _add(LogLevel.warning, message, error, stack);

  void e(String message, [Object? error, StackTrace? stack]) =>
      _add(LogLevel.error, message, error, stack);

  /// Restarts the `+elapsed` clock and writes a divider, so each
  /// experiment's lines are easy to find.
  void markSession(String label) {
    _sinceSession.reset();
    _add(LogLevel.info, '======== $label ========');
  }

  /// A line printed by someone else (a package or plugin), caught by the
  /// zone in main. It is stored but not echoed: it was printed already.
  void recordPrint(String line) =>
      _add(LogLevel.debug, 'print: $line', null, null, 'print', false);

  void clear() {
    _entries.clear();
    _dropped = 0;
  }

  /// Everything, oldest first, with a header saying which build and
  /// settings produced it.
  String dump() {
    final buffer = StringBuffer()
      ..writeln(
        'HandsOn Physics ${AppConfig.appVersion} debug log, '
        'protocol ${AppConfig.protocolVersion}',
      )
      ..writeln('copied: ${DateTime.now().toIso8601String()}')
      ..writeln(
        'build: ${kIsWeb ? 'web' : defaultTargetPlatform.name} '
        '${kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug')}',
      );
    try {
      context?.call().forEach((key, value) => buffer.writeln('$key: $value'));
    } catch (error) {
      buffer.writeln('context: unavailable ($error)');
    }
    buffer
      ..writeln('entries: ${_entries.length}, dropped: $_dropped')
      ..writeln();
    for (final entry in _entries) {
      buffer.writeln(entry.format());
    }
    return buffer.toString();
  }

  void _add(
    LogLevel level,
    String message, [
    Object? error,
    StackTrace? stack,
    String? caller,
    bool echoIt = true,
  ]) {
    final entry = LogEntry(
      time: DateTime.now(),
      elapsed: _sinceSession.elapsed,
      level: level,
      caller: caller ?? callerOf(StackTrace.current),
      message: message,
      error: error,
      stack: stack,
    );
    _entries.addLast(entry);
    if (_entries.length > capacity) {
      _entries.removeFirst();
      _dropped++;
    }
    if (echoIt) echo?.call(entry.format());
  }
}

/// The first frame in [trace] outside this file, as
/// `Class.method (path/file.dart:line)`, or `?` when the trace can't be
/// read (a minified web build, say).
@visibleForTesting
String callerOf(StackTrace trace) {
  for (final line in trace.toString().split('\n')) {
    final frame = _parseFrame(line.trim());
    if (frame == null || frame.file.endsWith('debug_log.dart')) continue;
    if (frame.file.startsWith('dart:') || frame.file.contains('dart-sdk/')) {
      continue;
    }
    final file = _shortPath(frame.file);
    return frame.line == null
        ? '${frame.member} ($file)'
        : '${frame.member} ($file:${frame.line})';
  }
  return '?';
}

// The VM and iOS builds: `#2  Foo.bar (package:app/x/y.dart:150:5)`.
final _vmFrame = RegExp(r'^#\d+\s+(.+?) \((.+?)(?::(\d+))?(?::\d+)?\)$');

// Debug web builds: `packages/app/x/y.dart 150:5  bar`.
final _webFrame = RegExp(r'^(\S+\.dart) (\d+)(?::\d+)?\s+(.+)$');

({String member, String file, int? line})? _parseFrame(String line) {
  final vm = _vmFrame.firstMatch(line);
  if (vm != null) {
    final number = int.tryParse(vm.group(3) ?? '');
    return (
      member: vm.group(1)!.replaceAll('<anonymous closure>', '<closure>'),
      file: vm.group(2)!,
      line: number == 0 ? null : number,
    );
  }
  final web = _webFrame.firstMatch(line);
  if (web != null) {
    return (
      member: web.group(3)!,
      file: web.group(1)!,
      line: int.tryParse(web.group(2)!),
    );
  }
  return null;
}

/// `package:hands_on_physics/state/x.dart` becomes `state/x.dart`; other
/// packages keep their name; files outside lib keep only their name.
String _shortPath(String path) {
  const app = 'hands_on_physics/';
  final inApp = path.indexOf(app);
  if (inApp >= 0) return path.substring(inApp + app.length);
  if (path.startsWith('package:') || path.startsWith('dart:')) {
    return path.replaceFirst('package:', '');
  }
  return path.split('/').last;
}
