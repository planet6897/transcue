import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../pipeline/subtitle_job.dart';
import '../settings/app_settings.dart';
import '../settings/settings_dialog.dart';
import '../source/youtube_url.dart';
import '../source/yt_dlp.dart';
import '../subtitle/bilingual_cue.dart';
import '../subtitle/dual_subtitle_overlay.dart';

/// 플레이어 화면: 로컬 파일 / YouTube 재생 + 이중 자막 오버레이.
/// 영상을 열면 [SubtitleJob]이 자막 확보(캐시·내장·YouTube·STT)와 번역을 진행한다.
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

  AppSettings _settings = AppSettings();
  SubtitleJob? _job;
  BilingualCue? _current;
  Duration _pos = Duration.zero;
  String _title = 'DualCue';
  bool _loading = false;
  bool _showOriginal = true;
  bool _showTranslation = true;

  List<BilingualCue> get _cues => _job?.cues ?? const [];

  @override
  void initState() {
    super.initState();
    AppSettings.load().then((s) {
      setState(() => _settings = s);
      // 개발용: DUALCUE_OPEN=<파일 경로> 로 실행하면 바로 연다 (실기기 자동 검증용)
      final auto = kDebugMode ? Platform.environment['DUALCUE_OPEN'] : null;
      if (auto != null && auto.isNotEmpty) unawaited(_openPath(auto));
    });
    _posSub = _player.stream.position.listen((pos) {
      _pos = pos;
      _updateCurrent();
    });
  }

  void _updateCurrent() {
    final next = cueAt(_cues, _pos);
    // 번역이 채워지면 같은 시간대라도 다른 객체가 되므로 identical로 비교
    if (!identical(next, _current)) setState(() => _current = next);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _job?.dispose();
    _player.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _startJob(JobSource source) {
    _job?.dispose();
    final job = SubtitleJob(source: source, settings: _settings);
    var lastLog = '';
    job.addListener(() {
      if (!mounted || _job != job) return;
      if (kDebugMode) {
        final t = job.cues.where((c) => c.translation != null).length;
        final log =
            '[job] ${job.stage.name} | ${job.status} | cues=${job.cues.length} ko=$t'
            '${job.notice == null ? '' : ' | ${job.notice}'}';
        // 진행률 숫자만 바뀌는 로그는 10% 단위로만 남긴다
        final key = log
            .replaceAllMapped(RegExp(r'(\d)\d%'), (m) => '${m[1]}x%')
            .replaceAll(RegExp(r'cues=\d+'), '');
        if (key != lastLog) {
          lastLog = key;
          debugPrint(log);
        }
      }
      _updateCurrent();
      setState(() {}); // 상태 표시줄 갱신
    });
    setState(() {
      _job = job;
      _current = null;
    });
    unawaited(job.run());
  }

  Future<void> _openFile() async {
    const videos = XTypeGroup(
      label: 'Video',
      extensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'],
    );
    final file = await openFile(acceptedTypeGroups: [videos]);
    if (file == null) return;
    await _openPath(file.path);
  }

  Future<void> _openPath(String path) async {
    setState(() => _title = path.split(Platform.pathSeparator).last);
    await _player.open(Media(path));
    _startJob(LocalFileSource(path));
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
      setState(() => _title = media.title);
      await _player.open(Media(media.videoUrl, httpHeaders: media.httpHeaders));
      if (media.audioUrl != null) {
        await _player.setAudioTrack(AudioTrack.uri(media.audioUrl!));
      }
      _startJob(YoutubeSource(media, _ytDlp));
    } catch (e) {
      debugPrint('YouTube open failed: $e');
      _toast('YouTube 열기 실패: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSettings() async {
    final osBefore = _settings.osApiKey;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => SettingsDialog(settings: _settings),
    );
    if (saved != true) return;
    await _settings.save();
    _toast('설정을 저장했습니다');
    // 키를 새로 넣었으면 지금 영상의 번역을 이어서 진행
    final job = _job;
    if (job == null) return;
    final finished = job.stage == JobStage.done || job.stage == JobStage.failed;
    // OpenSubtitles 키를 새로 넣었고 지금 자막이 음성 인식이면 인터넷 자막을 다시 찾는다
    if (finished &&
        _settings.osApiKey != osBefore &&
        _settings.hasOpenSubtitles &&
        job.originalFrom == SubtitleJob.fromStt) {
      _startJob(job.source);
    } else if (finished || job.stage == JobStage.transcribing) {
      unawaited(job.translateRemaining());
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
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
          IconButton(
            tooltip: '설정 (Claude API 키)',
            icon: Icon(
              Icons.settings,
              color: _settings.hasClaudeKey ? null : Colors.amber,
            ),
            onPressed: _openSettings,
          ),
        ],
        bottom: job == null ? null : _JobStatusBar(job: job),
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

/// 자막 생성/번역 진행 상태 (앱바 아래)
class _JobStatusBar extends StatelessWidget implements PreferredSizeWidget {
  const _JobStatusBar({required this.job});

  final SubtitleJob job;

  @override
  Size get preferredSize => const Size.fromHeight(30);

  @override
  Widget build(BuildContext context) {
    final busy = job.stage != JobStage.done && job.stage != JobStage.failed;
    final color = job.stage == JobStage.failed
        ? Theme.of(context).colorScheme.error
        : null;
    final notice = job.notice;
    return SizedBox(
      height: 30,
      child: Column(
        children: [
          if (busy)
            LinearProgressIndicator(value: job.progress, minHeight: 2)
          else
            const SizedBox(height: 2),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      job.status,
                      style: TextStyle(fontSize: 12, color: color),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (notice != null)
                    Flexible(
                      child: Text(
                        notice,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.amber,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
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
