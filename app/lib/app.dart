import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

class ProjectMaskApp extends StatelessWidget {
  const ProjectMaskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Project Mask',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF3D5AFE),
      ),
      home: const HomeScreen(),
    );
  }
}
