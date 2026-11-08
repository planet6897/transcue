import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../subtitle/bilingual_cue.dart';
import '../subtitle/dual_subtitle_overlay.dart';

/// M1 플레이어 화면: 파일 열기 + 재생 + 이중 자막 오버레이.
/// 자막 생성(STT)/번역 파이프라인은 M2/M3에서 Rust 코어와 연결한다.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<Duration>? _posSub;

  // TODO(M2/M3): 파이프라인 결과로 교체. 지금은 오버레이 확인용 샘플.
  final List<BilingualCue> _cues = const [
    BilingualCue(
      start: Duration(seconds: 1),
      end: Duration(seconds: 5),
      original: 'Welcome to DualCue.',
      translation: 'DualCue에 오신 것을 환영합니다.',
    ),
  ];
  BilingualCue? _current;
  bool _showOriginal = true;
  bool _showTranslation = true;

  @override
  void initState() {
    super.initState();
    _posSub = _player.stream.position.listen((pos) {
      final next = cueAt(_cues, pos);
      if (!identical(next, _current)) setState(() => _current = next);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _openFile() async {
    const videos = XTypeGroup(
      label: 'Video',
      extensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'],
    );
    final file = await openFile(acceptedTypeGroups: [videos]);
    if (file == null) return;
    await _player.open(Media(file.path));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DualCue'),
        actions: [
          IconButton(
            tooltip: '원문 자막',
            icon: Icon(_showOriginal ? Icons.subtitles : Icons.subtitles_off),
            onPressed: () => setState(() => _showOriginal = !_showOriginal),
          ),
          IconButton(
            tooltip: '번역 자막',
            icon: Icon(
              _showTranslation ? Icons.translate : Icons.g_translate_outlined,
            ),
            onPressed: () =>
                setState(() => _showTranslation = !_showTranslation),
          ),
          IconButton(
            tooltip: '동영상 열기',
            icon: const Icon(Icons.folder_open),
            onPressed: _openFile,
          ),
        ],
      ),
      body: Stack(
        children: [
          // media_kit 내장 자막 렌더링은 끄고 자체 오버레이를 사용한다.
          Video(
            controller: _controller,
            subtitleViewConfiguration: const SubtitleViewConfiguration(
              visible: false,
            ),
          ),
          DualSubtitleOverlay(
            cue: _current,
            showOriginal: _showOriginal,
            showTranslation: _showTranslation,
          ),
        ],
      ),
    );
  }
}
