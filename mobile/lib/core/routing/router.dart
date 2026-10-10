import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/calibration/calibration_screen.dart';
import '../../features/experiment/experiment_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../logging/debug_log.dart';

/// Route paths, so screens never type raw strings.
abstract final class Routes {
  static const home = '/';
  static const calibrate = '/calibrate';
  static const experiment = '/experiment';
  static const settings = '/settings';
}

/// Flow: home (pick an experiment) → calibrate → experiment.
/// Settings is reachable from home and from the experiment's banners.
final appRouter = buildAppRouter();

/// A fresh router; tests build their own so each starts at [initialLocation].
GoRouter buildAppRouter({String initialLocation = Routes.home}) => GoRouter(
  initialLocation: initialLocation,
  observers: [_LogRoutes()],
  routes: [
    GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
    GoRoute(
      path: Routes.calibrate,
      builder: (_, _) => const CalibrationScreen(),
    ),
    GoRoute(
      path: Routes.experiment,
      builder: (_, _) => const ExperimentScreen(),
    ),
    GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
  ],
);

/// Writes each screen change to the debug log.
class _LogRoutes extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      log.i('Opened ${_name(route)} over ${_name(previousRoute)}');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      log.i('Closed ${_name(route)}, back to ${_name(previousRoute)}');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      log.i('Replaced ${_name(oldRoute)} with ${_name(newRoute)}');

  static String _name(Route<dynamic>? route) => route == null
      ? 'nothing'
      : (route.settings.name ?? '${route.runtimeType}');
}
