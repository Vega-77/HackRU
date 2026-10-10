import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/logging/debug_log.dart';

void main() {
  // The zone puts every print, ours or a package's, in the debug log, and
  // catches async errors nothing else handled.
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        log.e(
          'Flutter error in ${details.library ?? 'unknown library'}'
          '${details.context == null ? '' : ', ${details.context}'}',
          details.exception,
          details.stack,
        );
        FlutterError.presentError(details);
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        log.e('Uncaught platform error', error, stack);
        return true;
      };
      AppLifecycleListener(
        onStateChange: (state) => log.i('App lifecycle: ${state.name}'),
      );
      log.i('App starting');
      runApp(const ProviderScope(child: HandsOnPhysicsApp()));
    },
    (error, stack) => log.e('Uncaught async error', error, stack),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        log.recordPrint(line);
        parent.print(zone, line);
      },
    ),
  );
}
