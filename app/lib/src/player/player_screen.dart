import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../source/youtube_url.dart';
import '../source/yt_dlp.dart';
import '../subtitle/bilingual_cue.dart';
import '../subtitle/dual_subtitle_overlay.dart';
import '../subtitle/webvtt.dart';

/// 플레이어 화면: 로컬 파일 / YouTube 재생 + 이중 자막 오버레이.
/// 자막 생성(STT)/번역 파이프라인은 M2/M3에서 Rust 코어와 연결한다.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, YtDlp? ytDlp}) : _ytDlp = ytDlp;

  final YtDlp? _ytDlp;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  late final YtDlp _ytDlp = widget._ytDlp ?? YtDlp();
  StreamSubscription<Duration>? _posSub;

  List<BilingualCue> _cues = const [];
  BilingualCue? _current;
  String _title = 'DualCue';
  bool _loading = false;
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

  void _setCues(List<BilingualCue> cues) => setState(() {
    _cues = cues;
    _current = null;
  });

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openFile() async {
    const videos = XTypeGroup(
      label: 'Video',
      extensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'],
    );
    final file = await openFile(acceptedTypeGroups: [videos]);
    if (file == null) return;
    _setCues(const []);
    setState(() => _title = file.name);
    await _player.open(Media(file.path));
  }

  Future<void> _openYoutube() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _YoutubeUrlDialog(),
    );
    if (url == null) return;
    final id = parseYoutubeId(url);
    if (id == null) {
      _toast('YouTube 링크가 아닙니다');
      return;
    }

    setState(() => _loading = true);
    try {
      final media = await _ytDlp.resolve(youtubeWatchUrl(id));
      _setCues(const []);
      setState(() => _title = media.title);
      await _player.open(Media(media.videoUrl, httpHeaders: media.httpHeaders));
      if (media.audioUrl != null) {
        await _player.setAudioTrack(AudioTrack.uri(media.audioUrl!));
      }
      await _loadYoutubeCaptions(media);
    } catch (e) {
      _toast('YouTube 열기 실패: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// YouTube가 제공하는 자막을 쓰면 STT/번역 비용 없이 바로 학습할 수 있다.
  Future<void> _loadYoutubeCaptions(YoutubeMedia media) async {
    final orig = media.original;
    if (orig == null) {
      _toast('이 영상에는 자막이 없습니다 (STT 자막 생성은 M2에서 지원)');
      return;
    }
    var cues = parseWebVtt(await fetchText(orig.url));
    final ko = media.korean;
    if (ko != null) {
      cues = mergeTranslation(cues, parseWebVtt(await fetchText(ko.url)));
    }
    _setCues(cues);

    final src = orig.auto ? '자동 생성' : '제공';
    final trans = ko == null
        ? '번역 없음 (AI 번역은 M3에서 지원)'
        : (ko.auto ? 'YouTube 자동 번역' : '한국어 자막');
    _toast('자막: ${orig.lang} $src · $trans');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title, overflow: TextOverflow.ellipsis),
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
            tooltip: 'YouTube 열기',
            icon: const Icon(Icons.smart_display),
            onPressed: _loading ? null : _openYoutube,
          ),
          IconButton(
            tooltip: '동영상 열기',
            icon: const Icon(Icons.folder_open),
            onPressed: _loading ? null : _openFile,
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
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

class _YoutubeUrlDialog extends StatefulWidget {
  const _YoutubeUrlDialog();

  @override
  State<_YoutubeUrlDialog> createState() => _YoutubeUrlDialogState();
}

class _YoutubeUrlDialogState extends State<_YoutubeUrlDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _text.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('YouTube 열기'),
      content: TextField(
        controller: _text,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'https://www.youtube.com/watch?v=...',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('열기')),
      ],
    );
  }
}
