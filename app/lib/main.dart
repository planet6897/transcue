import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/player/player_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const TranscueApp());
}

class TranscueApp extends StatelessWidget {
  const TranscueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Transcue · AI 동영상 플레이어',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        // 영상을 가리지 않는 반투명 알림
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xA6101018),
          elevation: 0,
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
          actionTextColor: const Color(0xFF80DEEA),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0x26FFFFFF)),
          ),
        ),
      ),
      home: const PlayerScreen(),
    );
  }
}
