import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../pipeline/subtitle_job.dart';
import '../settings/app_settings.dart';
import '../settings/settings_dialog.dart';
import '../source/youtube_url.dart';
import '../source/yt_dlp.dart';
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
  final _view = DualSubtitleState();
  final _videoKey = GlobalKey<VideoState>();

  AppSettings _settings = AppSettings();
  SubtitleJob? _job;
  String _title = 'DualCue';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    AppSettings.load().then((s) {
      setState(() => _settings = s);
      // 개발용: DUALCUE_OPEN=<파일 경로> 로 실행하면 바로 연다 (실기기 자동 검증용)
      final auto = kDebugMode ? Platform.environment['DUALCUE_OPEN'] : null;
      if (auto != null && auto.isNotEmpty) unawaited(_openPath(auto));
    });
  }

  @override
  void dispose() {
    _job?.dispose();
    _view.dispose();
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
      _view.cues = job.cues;
      setState(() {}); // 상태 표시줄 갱신
    });
    _view.cues = const [];
    setState(() => _job = job);
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
    if (kDebugMode) unawaited(_debugAutoplay());
  }

  /// 개발용: DUALCUE_SEEK=<초>, DUALCUE_FULLSCREEN=1 (실기기 화면 검증용)
  Future<void> _debugAutoplay() async {
    final env = Platform.environment;
    final seek = int.tryParse(env['DUALCUE_SEEK'] ?? '');
    if (seek != null) {
      await _player.stream.duration.firstWhere((d) => d > Duration.zero);
      await _player.seek(Duration(seconds: seek));
    }
    if (env['DUALCUE_FULLSCREEN'] == '1') {
      await Future<void>.delayed(const Duration(seconds: 1));
      await _videoKey.currentState?.enterFullscreen();
    }
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

  /// 재생 단축키. 영상에 포커스가 있을 때(일반/전체 화면)와 화면 전체에서 같이 쓴다.
  late final Map<ShortcutActivator, VoidCallback> _shortcuts = {
    for (final k in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.mediaPlayPause,
    ])
      SingleActivator(k): _player.playOrPause,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
        _seekBy(const Duration(seconds: -5)),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
        _seekBy(const Duration(seconds: 5)),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
        _player.setVolume((_player.state.volume + 5).clamp(0, 100)),
    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
        _player.setVolume((_player.state.volume - 5).clamp(0, 100)),
    // 자막 싱크 수동 조정: [ 0.2초 빠르게, ] 0.2초 늦게
    const SingleActivator(LogicalKeyboardKey.bracketLeft): () =>
        _nudge(const Duration(milliseconds: -200)),
    const SingleActivator(LogicalKeyboardKey.bracketRight): () =>
        _nudge(const Duration(milliseconds: 200)),
    const SingleActivator(LogicalKeyboardKey.keyF): () =>
        _videoKey.currentState?.toggleFullscreen(),
    const SingleActivator(LogicalKeyboardKey.escape): () {
      final v = _videoKey.currentState;
      if (v != null && v.isFullscreen()) v.exitFullscreen();
    },
  };

  Future<void> _nudge(Duration d) async {
    final job = _job;
    if (job == null) return;
    await job.nudge(d);
    final s = job.manualOffset.inMilliseconds / 1000;
    _toast('자막 ${s >= 0 ? '+' : ''}${s.toStringAsFixed(1)}초 ([ 빠르게 / ] 늦게)');
  }

  void _seekBy(Duration d) {
    final p = _player.state.position + d;
    _player.seek(p < Duration.zero ? Duration.zero : p);
  }

  /// 화면 클릭 = 재생/일시정지 (더블 클릭은 전체 화면)
  late final _controlsTheme = MaterialDesktopVideoControlsThemeData(
    playAndPauseOnTap: true,
    keyboardShortcuts: _shortcuts,
  );

  @override
  Widget build(BuildContext context) {
    final job = _job;
    // 툴바 버튼 등 영상 밖에 포커스가 있어도 Space/Enter로 재생/일시정지
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(_title, overflow: TextOverflow.ellipsis),
            actions: [
              // 툴바 버튼이 포커스를 가져가면 Space/Enter가 버튼을 누르게 되므로 제외
              ExcludeFocus(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '원문 자막',
                      icon: Icon(
                        _view.showOriginal
                            ? Icons.subtitles
                            : Icons.subtitles_off,
                      ),
                      onPressed: () => setState(
                        () => _view.showOriginal = !_view.showOriginal,
                      ),
                    ),
                    IconButton(
                      tooltip: '번역 자막',
                      icon: Icon(
                        _view.showTranslation
                            ? Icons.translate
                            : Icons.g_translate_outlined,
                      ),
                      onPressed: () => setState(
                        () => _view.showTranslation = !_view.showTranslation,
                      ),
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
                ),
              ),
            ],
            bottom: job == null ? null : _JobStatusBar(job: job),
          ),
          body: Stack(
            children: [
              // media_kit 내장 자막 렌더링은 끄고 자체 오버레이를 사용한다.
              MaterialDesktopVideoControlsTheme(
                normal: _controlsTheme,
                fullscreen: _controlsTheme,
                child: Video(
                  key: _videoKey,
                  controller: _controller,
                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                    visible: false,
                  ),
                  // controls 빌더는 전체 화면에서도 다시 쓰이므로 자막을 여기에 넣는다
                  controls: (state) => Stack(
                    children: [
                      LiveDualSubtitle(
                        position: _player.stream.position,
                        currentPosition: () => _player.state.position,
                        view: _view,
                      ),
                      MaterialDesktopVideoControls(state),
                    ],
                  ),
                ),
              ),
              if (_loading) const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
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
