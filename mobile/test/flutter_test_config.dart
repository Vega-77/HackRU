import 'dart:async';

import 'package:hands_on_physics/core/logging/debug_log.dart';

/// Runs before every test file: keeps the debug log out of test output.
/// Tests can still read what was logged.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  log.echo = null;
  await testMain();
}
