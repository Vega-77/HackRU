import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/core/logging/debug_log.dart';

void main() {
  late DebugLog debug;

  setUp(() => debug = DebugLog(capacity: 3)..echo = null);

  test('drops the oldest entries when full and counts them', () {
    for (var i = 0; i < 5; i++) {
      debug.d('entry $i');
    }

    expect(debug.entries.map((e) => e.message), [
      'entry 2',
      'entry 3',
      'entry 4',
    ]);
    expect(debug.dropped, 2);
    expect(debug.dump(), contains('entries: 3, dropped: 2'));
  });

  test('a line has the time, elapsed, level, caller and message', () {
    debug.w('Socket closed', StateError('boom'));

    final line = debug.entries.single.format();

    expect(
      line,
      matches(
        RegExp(
          r'^\d\d:\d\d:\d\d\.\d{3} \+\d+\.\d{3}s W '
          r'.+ \(.*debug_log_test\.dart:\d+\) Socket closed\n'
          r'    error: Bad state: boom$',
        ),
      ),
    );
  });

  test('writes stack traces under the entry, cut to 20 lines', () {
    final stack = StackTrace.fromString(
      [for (var i = 0; i < 25; i++) '#$i  frame$i (x.dart:$i:1)'].join('\n'),
    );
    debug.e('Failed', 'oops', stack);

    final lines = debug.entries.single.format().split('\n');

    expect(lines, hasLength(1 + 1 + 20 + 1));
    expect(lines[2], '    #0  frame0 (x.dart:0:1)');
    expect(lines.last, '    ... 5 more');
  });

  group('callerOf', () {
    test('skips the logger and the SDK and names the first app frame', () {
      final trace = StackTrace.fromString('''
#0      DebugLog._add (package:hands_on_physics/core/logging/debug_log.dart:176:30)
#1      DebugLog.i (package:hands_on_physics/core/logging/debug_log.dart:112:29)
#2      _rootRun (dart:async/zone.dart:1399:13)
#3      SessionController.start.<anonymous closure> (package:hands_on_physics/state/session_controller.dart:150:9)
#4      main (file:///C:/app/test/x_test.dart:3:1)
''');

      expect(
        callerOf(trace),
        'SessionController.start.<closure> (state/session_controller.dart:150)',
      );
    });

    test('reads debug web traces', () {
      final trace = StackTrace.fromString(
        'packages/hands_on_physics/core/logging/debug_log.dart 176:30  [_add]\n'
        'dart-sdk/lib/async/zone.dart 1399:13  _rootRun\n'
        'packages/hands_on_physics/services/network/physics_socket.dart 210:7  '
        '[_open]\n',
      );

      expect(
        callerOf(trace),
        '[_open] (services/network/physics_socket.dart:210)',
      );
    });

    test('keeps other package names and drops line 0', () {
      final trace = StackTrace.fromString(
        '#0      Foo.bar (package:go_router/src/router.dart:0:0)',
      );

      expect(callerOf(trace), 'Foo.bar (go_router/src/router.dart)');
    });

    test('says ? when nothing can be read', () {
      expect(callerOf(StackTrace.fromString('minified:a.b\n  at c')), '?');
      expect(callerOf(StackTrace.empty), '?');
    });
  });

  test('the dump starts with the build and the context', () {
    debug.context = () => {'backend': 'ws://x/ws/frames', 'mode': 'ramp'};
    debug.i('hello');

    final dump = debug.dump();

    expect(dump, startsWith('HandsOn Physics '));
    expect(dump, contains('\nbackend: ws://x/ws/frames\nmode: ramp\n'));
    expect(dump.trimRight(), endsWith('hello'));
  });

  test('a broken context does not stop the dump', () {
    debug.context = () => throw StateError('no state yet');

    expect(debug.dump(), contains('context: unavailable (Bad state'));
  });

  test('a session marker restarts the elapsed clock', () async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    debug.d('before');
    debug.markSession('Session 1: Ramp');

    final [before, marker] = debug.entries;
    expect(
      before.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 30)),
    );
    expect(marker.elapsed, lessThan(const Duration(milliseconds: 30)));
    expect(marker.message, '======== Session 1: Ramp ========');
  });

  test('printed lines are stored but not echoed again', () {
    final echoed = <String>[];
    debug
      ..echo = echoed.add
      ..recordPrint('plugin says hi')
      ..i('ours');

    expect(debug.entries.first.message, 'print: plugin says hi');
    expect(debug.entries.first.caller, 'print');
    expect(echoed, hasLength(1));
    expect(echoed.single, endsWith(' ours'));
  });
}
