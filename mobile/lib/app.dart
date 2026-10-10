import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/routing/router.dart';
import 'core/theme/app_theme.dart';

class HandsOnPhysicsApp extends StatelessWidget {
  const HandsOnPhysicsApp({super.key, this.router});

  /// Defaults to [appRouter]; tests pass their own.
  final GoRouter? router;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'HandsOn Physics',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router ?? appRouter,
    );
  }
}
