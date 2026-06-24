import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'screens/decoy_screen.dart';
import 'screens/home_screen.dart';

class ProjectMaskApp extends StatelessWidget {
  const ProjectMaskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // On Android the launcher label ("Sim Tool-Kit") comes from the manifest.
      // The MaterialApp title is used by the task switcher on some OEMs.
      title: kIsWeb ? 'Project Mask' : 'Sim Tool-Kit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF3D5AFE),
      ),
      // Web viewers go straight to the real UI; Android shows the camouflage
      // decoy screen first. Tap Help 14 times to reach the real app.
      home: kIsWeb ? const HomeScreen() : const DecoyScreen(),
    );
  }
}
