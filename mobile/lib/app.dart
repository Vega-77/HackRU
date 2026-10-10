import 'package:flutter/material.dart';

import 'core/routing/router.dart';
import 'core/theme/app_theme.dart';

class HandsOnPhysicsApp extends StatelessWidget {
  const HandsOnPhysicsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'HandsOn Physics',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: appRouter,
    );
  }
}
