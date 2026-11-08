import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/player/player_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const DualCueApp());
}

class DualCueApp extends StatelessWidget {
  const DualCueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DualCue',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const PlayerScreen(),
    );
  }
}
