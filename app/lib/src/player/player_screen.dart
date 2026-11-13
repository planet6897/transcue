import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../pipeline/stt_engine.dart' show canTranscribe;
import '../pipeline/subtitle_job.dart';
import '../settings/app_settings.dart';
import '../settings/settings_dialog.dart';
import '../source/ted_catalog.dart';
import '../source/youtube_url.dart';
import '../source/yt_dlp.dart';
import '../subtitle/bilingual_cue.dart';
import '../subtitle/dual_subtitle_overlay.dart';
import '../pipeline/tools.dart';
import 'file_browser.dart';
import 'play_counts.dart';
import 'playlist.dart';
import 'recent_videos.dart';
import 'resume.dart';
import 'sentence_loop.dart';
import 'ted_browser.dart';
import 'volume_gesture.dart';

/// 자막 다시 만들기 메뉴
enum _Regen {
  fetch(
    '자막 다시 가져오기',
    '저장된 자막과 번역을 무시하고 내장·인터넷·YouTube 자막을 다시 찾습니다. '
        '없으면 음성 인식으로 만들고, 번역도 새로 합니다. API 비용이 다시 발생합니다.',
  ),
  speech(
    '음성 인식으로 새로 만들기',
    '저장된 자막과 번역을 무시하고 음성 인식으로 자막을 새로 만든 뒤 번역합니다. '
        '시간이 걸리고 API 비용이 다시 발생합니다.',
  );

  const _Regen(this.label, this.detail);
  final String label;
  final String detail;
}

/// 플레이어 화면: 로컬 파일 / YouTube 재생 + 이중 자막 오버레이.
/// 영상을 열면 [SubtitleJob]이 자막 확보(캐시·내장·YouTube·STT)와 번역을 진행한다.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, YtDlp? ytDlp}) : _ytDlp = ytDlp;

  final YtDlp? _ytDlp;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player(
    configuration: PlayerConfiguration(
      logLevel: kDebugMode ? MPVLogLevel.warn : MPVLogLevel.error,
    ),
  );
  late final VideoController _controller = VideoController(_player);
  late final YtDlp _ytDlp = widget._ytDlp ?? YtDlp();
  final _view = DualSubtitleState();
  final _videoKey = GlobalKey<VideoState>();

  AppSettings _settings = AppSettings();
  SubtitleJob? _job;
  String _title = 'Transcue · AI 동영상 플레이어';
  bool _loading = false;

  /// 영상을 연 적이 있는지 (열기 전에는 메뉴를 항상 보여 준다)
  bool _opened = false;

  /// YouTube 열기 버튼 표시 여부 (기능은 남겨 두고 메뉴에서만 숨긴다)
  final bool _showYoutubeButton = false;

  /// 전체 화면에서도 상단 줄을 갱신하기 위한 알림 ([setState]마다 올린다)
  final _uiChanged = ValueNotifier<int>(0);

  /// 전체 화면에서 보여 줄 안내 (SnackBar는 전체 화면 뒤에 가려진다)
  final _flash = ValueNotifier<String?>(null);
  final _centerHint = ValueNotifier<Widget?>(null); // 화살표 키 조작 표시

  /// 데스크톱 화면 밝기 (영상을 덮어 어둡게 한다, 1 = 원래 밝기). 앱을 다시 열면 돌아온다.
  final _screenBrightness = ValueNotifier<double>(1);
  Timer? _flashTimer;

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _uiChanged.value++;
  }

  /// 지금 재생 중인 로컬 파일 (YouTube면 null) — 연속 재생 기준
  String? _currentPath;
  StreamSubscription<bool>? _completedSub;

  /// 이어 보기: 지금 영상의 키와 위치 기록
  PlaybackPositions? _positions;
  String? _resumeKey;
  Timer? _positionTimer;
  StreamSubscription<bool>? _playingSub;

  /// 문장 반복 (켜져 있을 때만 있다). 횟수는 끄고 다시 켜도 기억한다.
  SentenceLoop? _sentenceLoop;
  var _sentenceRepeat = SentenceRepeat.forever;
  StreamSubscription<Duration>? _sentenceLoopSub;

  /// 지금 영상의 반복 재생 상태와 재생 횟수 (화면 표시용)
  final _playInfo = ValueNotifier<({bool repeat, int count})>((
    repeat: false,
    count: 0,
  ));
  PlayCounts? _counts;
  RecentVideos? _recent;
  String? _countKey;

  /// 앱 종료 전에 플레이어를 먼저 닫는다.
  /// 안 닫으면 Dart가 내려간 뒤 mpv가 이벤트를 보내 종료 시 비정상 종료(SIGABRT)된다
  /// (크래시 리포트: DLRT_GetFfiCallbackMetadata ← mp_client_send_property_changes)
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onExitRequested: _beforeExit,
  );
  bool _playerClosed = false;

  Future<AppExitResponse> _beforeExit() async {
    await _rememberPosition();
    if (!_playerClosed) {
      _playerClosed = true;
      await _player.dispose();
    }
    return AppExitResponse.exit;
  }

  @override
  void initState() {
    super.initState();
    _lifecycle; // 종료 요청 감시 시작
    if (kDebugMode) {
      final vol = double.tryParse(Platform.environment['DUALCUE_VOLUME'] ?? '');
      if (vol != null) unawaited(_player.setVolume(vol));
      _player.stream.log.listen(
        (l) => debugPrint('[mpv] ${l.prefix}: ${l.text}'),
      );
    }
    _completedSub = _player.stream.completed.listen((done) {
      if (done) _onCompleted();
    });
    // 재생 중 5초마다, 그리고 일시정지할 때 위치를 기록
    _positionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_player.state.playing) unawaited(_rememberPosition());
    });
    _playingSub = _player.stream.playing.listen((p) {
      if (kDebugMode) debugPrint('[playing] $p');
      if (p) _pausedByCopy = false;
      if (!p) unawaited(_rememberPosition());
    });
    AppSettings.load().then((s) {
      setState(() => _settings = s);
      _view.showVocab = s.showVocab;
      _publishPlayInfo();
      // 개발용: DUALCUE_OPEN=<파일 경로> 로 실행하면 바로 연다 (실기기 자동 검증용)
      // DUALCUE_OPEN=ted 는 TED 강연 목록을 연다
      final auto = kDebugMode ? Platform.environment['DUALCUE_OPEN'] : null;
      if (auto == 'ted') {
        unawaited(_openTed());
      } else if (auto != null && auto.isNotEmpty) {
        unawaited(
          parseYoutubeId(auto) != null
              ? _openYoutubeUrl(auto)
              : _openPath(auto),
        );
      } else {
        unawaited(_showRecentOnStart());
      }
    });
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _sentenceLoopSub?.cancel();
    _playingSub?.cancel();
    _positionTimer?.cancel();
    unawaited(_rememberPosition());
    _lifecycle.dispose();
    _job?.dispose();
    _view.dispose();
    _playInfo.dispose();
    _uiChanged.dispose();
    _flashTimer?.cancel();
    _flash.dispose();
    _centerHintTimer?.cancel();
    _centerHint.dispose();
    _screenBrightness.dispose();
    if (!_playerClosed) {
      _playerClosed = true;
      _player.dispose();
    }
    super.dispose();
  }

  /// 화면 아래 가운데에 작게 뜨는 알림
  SnackBar _snack(
    String text, {
    Duration duration = const Duration(milliseconds: 2500),
    SnackBarAction? action,
  }) => SnackBar(
    content: Text(text, textAlign: TextAlign.center),
    width: (MediaQuery.sizeOf(context).width - 32).clamp(0, 460).toDouble(),
    // 버튼이 있는 알림은 기본으로 계속 떠 있어 자막을 가린다
    persist: false,
    duration: duration,
    action: action,
  );

  void _toast(String msg) {
    if (!mounted) return;
    if (_videoKey.currentState?.isFullscreen() ?? false) {
      _flash.value = msg;
      _flashTimer?.cancel();
      _flashTimer = Timer(
        const Duration(seconds: 2),
        () => _flash.value = null,
      );
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(_snack(msg));
  }

  void _startJob(JobSource source, {JobRefresh refresh = JobRefresh.none}) {
    // 개발용: DUALCUE_NO_JOB=1 이면 자막 작업(인식/번역 비용)을 건너뛴다
    if (kDebugMode && Platform.environment['DUALCUE_NO_JOB'] == '1') return;
    _job?.dispose();
    final job = SubtitleJob(
      source: source,
      settings: _settings,
      refresh: refresh,
      playhead: () => _player.state.position,
      mediaDuration: () => _player.state.duration,
    );
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
    if (Platform.isAndroid) {
      final cur = _currentPath;
      final path = await pickVideoOnAndroid(
        context,
        startDir: cur?.substring(0, cur.lastIndexOf('/')),
      );
      if (path != null) await _openPath(path);
      return;
    }
    const videos = XTypeGroup(
      label: 'Video',
      extensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'],
    );
    final file = await openFile(acceptedTypeGroups: [videos]);
    if (file == null) return;
    await _openPath(file.path);
  }

  Future<void> _openPath(String path) async {
    await _rememberPosition(); // 보던 영상의 위치를 먼저 기록
    setState(() {
      _title = path.split(Platform.pathSeparator).last;
      _currentPath = path;
      _opened = true;
    });
    if (kDebugMode) debugPrint('[open] $path');
    _resumeKey = null;
    await _beginCount(PlaybackPositions.keyForPath(path));
    unawaited(_rememberRecent(path, _title));
    final loaded = _durationLoaded();
    await _player.open(Media(path));
    // 자막 작업은 재생 위치부터 시작하므로 이어 보기 위치로 먼저 옮긴다
    await _resumeAt(PlaybackPositions.keyForPath(path), loaded);
    _startJob(LocalFileSource(path));
    if (kDebugMode) unawaited(_debugAutoplay());
  }

  /// 개발용: 실제로 소리 트랙이 재생 중인지 로그로 확인
  Future<void> _debugAudioState() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    for (final sec in [5, 10, 20]) {
      await Future<void>.delayed(
        Duration(seconds: sec == 5 ? 5 : sec / 2 ~/ 1),
      );
      final aid = await native.getProperty('aid');
      final codec = await native.getProperty('current-tracks/audio/codec');
      final vcodec = await native.getProperty('current-tracks/video/codec');
      final h = await native.getProperty('current-tracks/video/demux-h');
      debugPrint(
        '[audio] t=${sec}s aid=$aid codec=$codec video=$vcodec ${h}p '
        'playing=${_player.state.playing} pos=${_player.state.position} '
        'buffering=${_player.state.buffering}',
      );
    }
  }

  /// 개발용: DUALCUE_SEEK=<초>, DUALCUE_FULLSCREEN=1 (실기기 화면 검증용)
  Future<void> _debugAutoplay() async {
    final env = Platform.environment;
    if (env['DUALCUE_REPEAT'] == '1') {
      _settings.repeatVideo = true;
      _publishPlayInfo();
    }
    final regen = _Regen.values.asNameMap()[env['DUALCUE_REGEN']];
    final job = _job;
    if (regen != null && job != null) {
      while (job.stage != JobStage.done && job.stage != JobStage.failed) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      debugPrint('[regen] ${regen.name}');
      _applyRegen(regen);
    }
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
    await _openYoutubeUrl(url);
  }

  /// TED 강연 목록(최신·분류·검색)에서 고른 영상을 연다 (YouTube TED 채널)
  Future<void> _openTed() async {
    final dir = (await AppSettings.supportDir()).path;
    final counts = await _countStore();
    if (!mounted) return;
    final id = await showDialog<String>(
      context: context,
      builder: (_) => TedBrowserDialog(
        catalog: TedCatalog(_ytDlp, File('$dir/ted_catalog.json')),
        watched: (id) async =>
            await counts.get(PlaybackPositions.keyForYoutube(id)) > 0,
      ),
    );
    if (id == null) return;
    await _openYoutubeUrl(youtubeWatchUrl(id));
  }

  Future<void> _openYoutubeUrl(String url) async {
    final id = parseYoutubeId(url);
    if (id == null) {
      _toast('YouTube 링크가 아닙니다');
      return;
    }

    setState(() => _loading = true);
    try {
      final media = await _ytDlp.resolve(youtubeWatchUrl(id));
      setState(() {
        _title = media.title;
        _currentPath = null;
        _opened = true;
      });
      // 고화질은 영상/소리가 따로 온다. 소리는 영상이 실제로 로드된 뒤에 붙여야 한다
      // (open()은 로드 완료 전에 반환되고, 그 사이 mpv audio-add는 조용히 실패함)
      await _rememberPosition();
      _resumeKey = null;
      await _beginCount(PlaybackPositions.keyForYoutube(id));
      unawaited(_rememberRecent(youtubeWatchUrl(id), media.title));
      final loaded = _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 30));
      await _player.open(Media(media.videoUrl, httpHeaders: media.httpHeaders));
      if (media.audioUrl != null) {
        await loaded;
        await _player.setAudioTrack(AudioTrack.uri(media.audioUrl!));
      }
      await _resumeAt(PlaybackPositions.keyForYoutube(id), loaded);
      if (kDebugMode) unawaited(_debugAudioState());
      _startJob(YoutubeSource(media, _ytDlp));
    } catch (e) {
      debugPrint('YouTube open failed: $e');
      _toast('YouTube 열기 실패: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<PlaybackPositions> _positionStore() async =>
      _positions ??= PlaybackPositions(
        File('${(await AppSettings.supportDir()).path}/positions.json'),
      );

  /// 새 영상의 길이가 알려질 때까지 (open 전에 불러 둔다)
  Future<Duration?> _durationLoaded() => _player.stream.duration
      .firstWhere((d) => d > Duration.zero)
      .timeout(const Duration(seconds: 15))
      .then<Duration?>((d) => d, onError: (_) => null);

  /// 지금 영상의 재생 위치 기록
  Future<void> _rememberPosition() async {
    final key = _resumeKey;
    if (key == null) return;
    final store = await _positionStore();
    final changed = await store.put(
      key,
      _player.state.position,
      _player.state.duration,
    );
    if (changed) await store.save();
  }

  /// 이전에 보던 위치가 있으면 거기로 옮긴다
  Future<void> _resumeAt(String key, Future<Duration?> loaded) async {
    final at = await (await _positionStore()).get(key);
    if (at != null && await loaded != null) {
      await _player.seek(at);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            _snack(
              '이전에 보던 ${formatPosition(at)}부터 재생합니다',
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: '처음부터',
                onPressed: () => _player.seek(Duration.zero),
              ),
            ),
          );
      }
    }
    _resumeKey = key; // 옮긴 뒤부터 기록 (옮기기 전 0초가 기록되지 않게)
  }

  Future<RecentVideos> _recentStore() async => _recent ??= RecentVideos(
    File('${(await AppSettings.supportDir()).path}/recent.json'),
  );

  Future<void> _rememberRecent(String source, String title) async =>
      (await _recentStore()).add(source, title);

  /// 앱을 켜면 최근 재생목록을 바로 띄운다 (목록이 비어 있으면 띄우지 않는다)
  Future<void> _showRecentOnStart() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _opened) return;
    if ((await (await _recentStore()).list()).isNotEmpty) await _showRecent();
  }

  /// 최근 재생목록을 보여 주고 고른 영상을 연다
  Future<void> _showRecent() async {
    await _rememberPosition(); // 지금 보던 위치도 목록에 반영
    final store = await _recentStore();
    final positions = await _positionStore();
    final counts = await _countStore();
    final rows = <RecentRow>[];
    for (final v in await store.list()) {
      final id = parseYoutubeId(v.source);
      final key = id != null
          ? PlaybackPositions.keyForYoutube(id)
          : PlaybackPositions.keyForPath(v.source);
      rows.add(
        RecentRow(
          video: v,
          resumeAt: await positions.get(key),
          playCount: await counts.get(key),
          available: id != null || await File(v.source).exists(),
        ),
      );
    }
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => RecentVideosDialog(
        rows: rows,
        onRemove: (s) => unawaited(store.remove(s)),
      ),
    );
    if (picked == null) return;
    await (parseYoutubeId(picked) != null
        ? _openYoutubeUrl(picked)
        : _openPath(picked));
  }

  Future<PlayCounts> _countStore() async => _counts ??= PlayCounts(
    File('${(await AppSettings.supportDir()).path}/play_counts.json'),
  );

  void _publishPlayInfo([int? count]) {
    _playInfo.value = (
      repeat: _settings.repeatVideo,
      count: count ?? _playInfo.value.count,
    );
  }

  /// 새 영상을 열 때 그 영상의 재생 횟수를 불러온다
  Future<void> _beginCount(String key) async {
    _countKey = key;
    final n = await (await _countStore()).get(key);
    if (_countKey == key) _publishPlayInfo(n);
  }

  Future<void> _countPlay() async {
    final key = _countKey;
    if (key == null) return;
    final n = await (await _countStore()).increment(key);
    if (kDebugMode) debugPrint('[repeat] count=$n');
    if (_countKey == key) _publishPlayInfo(n);
  }

  Future<void> _resetCount() async {
    final key = _countKey;
    if (key == null) return;
    await (await _countStore()).reset(key);
    if (_countKey == key) _publishPlayInfo(0);
    _toast('재생 횟수를 초기화했습니다');
  }

  Future<void> _toggleRepeat() async {
    setState(() => _settings.repeatVideo = !_settings.repeatVideo);
    _publishPlayInfo();
    await _settings.save();
    _toast(_settings.repeatVideo ? '반복 재생 켜짐 (R)' : '반복 재생 꺼짐 (R)');
  }

  /// 자막 복사 때문에 멈춘 상태인지 (재생이 다시 시작되면 해제)
  bool _pausedByCopy = false;

  /// 자막을 누르면 영상을 멈추고 화면에 보이는 줄을 복사한다
  Future<void> _copyCue(BilingualCue cue) async {
    // 복사하려고 멈춘 상태에서 자막을 다시 누르면 이어서 재생한다
    if (_pausedByCopy && !_player.state.playing) {
      await _player.play();
      return;
    }
    _pausedByCopy = true;
    await _player.pause();
    final text = _view.copyText(cue);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _view.flashCopied();
  }

  /// 자막이 이상할 때 한 번에 AI로 다시 번역한다
  void _retranslate() {
    _toast('AI로 다시 번역합니다');
    unawaited(_job?.retranslate());
  }

  /// PopupMenuButton은 메뉴가 떠 있는 사이 조작부가 자동으로 사라져 버튼이 없어지면
  /// 고른 항목을 버린다. 그래서 메뉴를 직접 띄워 결과를 받는다.
  // ---- 문장 반복 ----

  /// 문장 반복 켜기/끄기 (L)
  void _toggleSentenceLoop() =>
      _setSentenceLoop(_sentenceLoop == null ? _sentenceRepeat : null);

  /// [repeat]으로 문장 반복을 켠다. null이면 끈다.
  void _setSentenceLoop(SentenceRepeat? repeat) {
    if (repeat == null) {
      _sentenceLoopSub?.cancel();
      _sentenceLoopSub = null;
      setState(() => _sentenceLoop = null);
      _toast('문장 반복 꺼짐 (L)');
      return;
    }
    _sentenceRepeat = repeat;
    final loop = _sentenceLoop;
    if (loop != null) {
      setState(() => loop.repeat = repeat);
    } else {
      final created = SentenceLoop(repeat)
        ..lockAt(_view.cues, _player.state.position);
      setState(() => _sentenceLoop = created);
      _sentenceLoopSub = _player.stream.position.listen(_onLoopPosition);
    }
    _toast(
      _view.cues.isEmpty
          ? '문장 반복 켜짐 · ${repeat.label} (자막이 생기면 반복합니다)'
          : '문장 반복 켜짐 · ${repeat.label} (L)',
    );
  }

  void _onLoopPosition(Duration pos) {
    final loop = _sentenceLoop;
    if (loop == null) return;
    final before = (loop.cue, loop.round);
    final back = loop.onPosition(_view.cues, pos);
    if (back != null) {
      if (kDebugMode) {
        debugPrint(
          '[loop] ${pos.inMilliseconds}ms -> ${back.inMilliseconds}ms '
          'round ${loop.round} "${loop.cue?.original}"',
        );
      }
      unawaited(_player.seek(back));
    }
    // 몇 번째 듣는지 버튼에 보여 준다 (바뀔 때만 다시 그린다)
    if (before != (loop.cue, loop.round) && mounted) setState(() {});
  }

  /// 문장 반복 버튼: 횟수를 고르거나 끈다
  Future<void> _showSentenceLoopMenu(BuildContext button) async {
    final box = button.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(button).overlay!.context.findRenderObject()! as RenderBox;
    final on = _sentenceLoop?.repeat;
    final picked = await showMenu<SentenceRepeat?>(
      context: button,
      position: RelativeRect.fromRect(
        box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final r in SentenceRepeat.values)
          CheckedPopupMenuItem(
            value: r,
            checked: on == r,
            child: Text(r.label),
          ),
        if (on != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: null,
            onTap: () => _menuPickedOff = true,
            child: const Text('끄기'),
          ),
        ],
      ],
    );
    // 메뉴 밖을 눌러 닫으면 picked도 null이므로, 끄기는 켜져 있을 때 고른 경우만
    if (!mounted) return;
    if (picked != null) {
      _setSentenceLoop(picked);
    } else if (on != null && _menuPickedOff) {
      _setSentenceLoop(null);
    }
    _menuPickedOff = false;
  }

  /// '끄기'를 골랐는지 (메뉴 밖을 눌러 닫은 것과 구별)
  var _menuPickedOff = false;

  Widget _sentenceLoopButton() {
    final loop = _sentenceLoop;
    final times = loop?.repeat.times;
    final tip = loop == null
        ? '문장 반복 꺼짐 (L)'
        : '문장 반복 켜짐 · ${loop.repeat.label} (L)';
    final icon = Icon(
      Icons.loop,
      color: loop == null ? null : const Color(0xFF80DEEA),
    );
    return Builder(
      builder: (button) => IconButton(
        tooltip: tip,
        icon: loop == null || loop.cue == null
            ? icon
            : Badge(
                label: Text(
                  times == 0 ? '${loop.round}' : '${loop.round}/$times',
                ),
                child: icon,
              ),
        onPressed: () => _showSentenceLoopMenu(button),
      ),
    );
  }

  Future<void> _showRegenMenu(BuildContext button) async {
    final box = button.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(button).overlay!.context.findRenderObject()! as RenderBox;
    final regen = await showMenu<_Regen>(
      context: button,
      position: RelativeRect.fromRect(
        box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: _Regen.fetch, child: Text(_Regen.fetch.label)),
        if (canTranscribe)
          PopupMenuItem(value: _Regen.speech, child: Text(_Regen.speech.label)),
      ],
    );
    if (regen != null && mounted) await _confirmRegen(regen);
  }

  /// 자막 다시 만들기: 비용이 드는 작업이라 먼저 확인한다
  Future<void> _confirmRegen(_Regen regen) async {
    final job = _job;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(regen.label),
        content: Text(regen.detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('다시 만들기'),
          ),
        ],
      ),
    );
    if (ok == true && job != null && identical(job, _job)) _applyRegen(regen);
  }

  void _applyRegen(_Regen regen) {
    final job = _job;
    if (job == null) return;
    switch (regen) {
      case _Regen.fetch:
        _startJob(job.source, refresh: JobRefresh.fetch);
      case _Regen.speech:
        _startJob(job.source, refresh: JobRefresh.speech);
    }
  }

  /// 영상이 끝났을 때: 반복 재생이면 처음부터, 연속 재생이 켜져 있으면 다음 영상
  void _onCompleted() {
    unawaited(_rememberPosition()); // 끝까지 봤으면 기록 지움
    unawaited(_countPlay());
    if (_settings.repeatVideo) {
      unawaited(_player.seek(Duration.zero).then((_) => _player.play()));
      return;
    }
    final path = _currentPath;
    if (!_settings.autoPlayNext || path == null) return;
    final next = neighborVideo(path);
    if (next == null) {
      _toast('마지막 영상입니다');
      return;
    }
    _toast('다음 영상: ${next.split(Platform.pathSeparator).last}');
    // 끝 화면을 잠깐 보여 준 뒤 넘어간다. 그 사이 사용자가 다른 영상을 열었으면 취소
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && _currentPath == path) _openPath(next);
    });
  }

  /// 이전/다음 영상으로 이동 (P / N)
  void _skip(int delta) {
    final path = _currentPath;
    if (path == null) return;
    final target = neighborVideo(path, delta: delta);
    if (target == null) {
      _toast(delta > 0 ? '다음 영상이 없습니다' : '이전 영상이 없습니다');
      return;
    }
    _openPath(target);
  }

  Future<void> _toggleAutoPlayNext() async {
    setState(() => _settings.autoPlayNext = !_settings.autoPlayNext);
    await _settings.save();
    _toast(_settings.autoPlayNext ? '연속 재생 켜짐' : '연속 재생 꺼짐');
  }

  Future<void> _openSettings() async {
    final osBefore = _settings.osApiKey;
    final levelBefore = _settings.vocabLevel;
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
    if (_settings.vocabLevel != levelBefore) job.resetVocab();
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
        _seekByKey(-1, const Duration(seconds: -5)),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
        _seekByKey(1, const Duration(seconds: 5)),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
        _changeVolume(volumeKeyStep),
    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
        _changeVolume(-volumeKeyStep),
    // 자막 싱크 수동 조정: [ 0.2초 빠르게, ] 0.2초 늦게
    const SingleActivator(LogicalKeyboardKey.bracketLeft): () =>
        _nudge(const Duration(milliseconds: -200)),
    const SingleActivator(LogicalKeyboardKey.bracketRight): () =>
        _nudge(const Duration(milliseconds: 200)),
    const SingleActivator(LogicalKeyboardKey.keyV): _toggleVocab,
    const SingleActivator(LogicalKeyboardKey.keyR): _toggleRepeat,
    const SingleActivator(LogicalKeyboardKey.keyL): _toggleSentenceLoop,
    const SingleActivator(LogicalKeyboardKey.keyR, shift: true): _resetCount,
    // 처음부터
    const SingleActivator(LogicalKeyboardKey.home): () =>
        _player.seek(Duration.zero),
    // 이전/다음 영상
    const SingleActivator(LogicalKeyboardKey.keyN): () => _skip(1),
    const SingleActivator(LogicalKeyboardKey.keyP): () => _skip(-1),
    const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () => _skip(1),
    const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
        _skip(-1),
    const SingleActivator(LogicalKeyboardKey.keyF): () =>
        _videoKey.currentState?.toggleFullscreen(),
    const SingleActivator(LogicalKeyboardKey.escape): () {
      final v = _videoKey.currentState;
      if (v != null && v.isFullscreen()) v.exitFullscreen();
    },
  };

  /// 학습 단어 켜기/끄기 (켜져 있을 때만 Claude로 단어를 만든다)
  Future<void> _toggleVocab() async {
    final on = !_settings.showVocab;
    setState(() {
      _settings.showVocab = on;
      _view.showVocab = on;
    });
    await _settings.save();
    if (on) _job?.kickVocab();
    _toast(on ? '학습 단어 켜짐 (V)' : '학습 단어 꺼짐 (V)');
  }

  Future<void> _nudge(Duration d) async {
    final job = _job;
    if (job == null) return;
    await job.nudge(d);
    final s = job.manualOffset.inMilliseconds / 1000;
    _toast('자막 ${s >= 0 ? '+' : ''}${s.toStringAsFixed(1)}초 ([ 빠르게 / ] 늦게)');
  }

  double? _volumeTarget;
  DateTime _volumeChangedAt = DateTime(0);
  Timer? _centerHintTimer;

  /// 화살표 키로 조작한 내용을 화면 가운데에 잠깐 보여 준다
  void _showCenterHint(Widget hint) {
    _centerHint.value = hint;
    _centerHintTimer?.cancel();
    _centerHintTimer = Timer(
      const Duration(seconds: 1),
      () => _centerHint.value = null,
    );
  }

  /// 영상 위에서 휠: 오른쪽 절반은 소리, 왼쪽 절반은 밝기 (Android 위/아래 밀기와 같은 배치)
  void _onWheel(PointerSignalEvent e, double width) {
    if (e is! PointerScrollEvent) return;
    final step = wheelStep(e.scrollDelta);
    if (step == 0) return;
    // 같은 휠 입력을 다른 곳(목록 스크롤 등)과 나눠 처리하지 않게 한 곳만 받는다
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      if (e.localPosition.dx < width / 2) {
        _changeBrightness(step * brightnessStep);
      } else {
        _changeVolume(step * volumeKeyStep);
      }
    });
  }

  /// 화면 밝기를 바꾸고 화면 가운데에 잠깐 보여 준다 (데스크톱)
  void _changeBrightness(double delta) {
    final b = steppedBrightness(_screenBrightness.value, delta);
    _screenBrightness.value = b;
    _showCenterHint(VolumeIndicator(value: b, brightness: true));
  }

  /// 음량을 바꾸고 화면 가운데에 잠깐 보여 준다
  void _changeVolume(double delta) {
    // 키를 누르고 있으면 플레이어 값이 갱신되기 전에 다음 입력이 오므로 직전 목표값을 기준으로 한다
    final now = DateTime.now();
    final recent = now.difference(_volumeChangedAt).inMilliseconds < 500;
    final from = recent
        ? (_volumeTarget ?? _player.state.volume)
        : _player.state.volume;
    final target = steppedVolume(from, delta);
    _volumeTarget = target;
    _volumeChangedAt = now;
    unawaited(_player.setVolume(target));
    _showCenterHint(VolumeIndicator(value: target / 100));
  }

  Duration? _sentenceTarget;
  DateTime _sentenceSeekAt = DateTime(0);

  /// 문장 단위 이동. 갈 문장이 없으면(자막이 아직 없는 구간 등) [fallback]만큼 이동한다.
  /// 문장 단위로 이동했으면 true, [fallback]만큼 이동했으면 false를 돌려준다.
  bool _seekSentence(int direction, Duration fallback) {
    // 연달아 누르면 재생 위치가 갱신되기 전이므로 직전 목표 위치를 기준으로 한다
    final now = DateTime.now();
    final recent = now.difference(_sentenceSeekAt).inMilliseconds < 500;
    final from = recent
        ? (_sentenceTarget ?? _player.state.position)
        : _player.state.position;
    final target = sentenceSeekTarget(_view.cues, from, direction);
    if (target == null) {
      _seekBy(fallback);
      return false;
    }
    _sentenceTarget = target;
    _sentenceSeekAt = now;
    // 문장 반복 중이면 옮긴 문장을 처음부터 반복한다
    _sentenceLoop?.lockAt(_view.cues, target);
    _player.seek(target);
    return true;
  }

  /// 좌우 화살표: 이동하고 어디로 갔는지 화면에 보여 준다
  void _seekByKey(int direction, Duration fallback) {
    final forward = direction > 0;
    final bySentence = _seekSentence(direction, fallback);
    _showCenterHint(
      _SeekHint(
        forward: forward,
        label: bySentence
            ? (forward ? '다음 문장' : '이전 문장')
            : '${fallback.inSeconds.abs()}초 ${forward ? '앞으로' : '뒤로'}',
      ),
    );
  }

  DateTime _lastVideoClick = DateTime(0);

  /// 영상 클릭 = 재생/일시정지, 더블 클릭 = 전체 화면
  void _onVideoClick() {
    _player.playOrPause();
    final now = DateTime.now();
    if (now.difference(_lastVideoClick).inMilliseconds < 400) {
      _videoKey.currentState?.toggleFullscreen();
    }
    _lastVideoClick = now;
  }

  void _seekBy(Duration d) {
    final p = _player.state.position + d;
    _player.seek(p < Duration.zero ? Duration.zero : p);
  }

  /// 영상 클릭은 [_onVideoClick]이 처리한다. 조작부의 자체 재생/일시정지는 누르는 순간
  /// 동작해서 상단 메뉴 버튼을 눌러도 영상이 멈춘다.
  late final _controlsTheme = MaterialDesktopVideoControlsThemeData(
    playAndPauseOnTap: false,
    toggleFullscreenOnDoublePress: false,
    // 휠은 [_onWheel]이 처리한다 (오른쪽은 소리·왼쪽은 밝기, 가운데 표시)
    modifyVolumeOnScroll: false,
    visibleOnMount: _pinControls,
    controlsHoverDuration: _pinControls
        ? const Duration(hours: 1)
        : const Duration(seconds: 3),
    keyboardShortcuts: _shortcuts,
    topButtonBar: [Expanded(child: _topBar())],
    bottomButtonBar: [
      const MaterialDesktopSkipPreviousButton(),
      _desktopSeekButton(Icons.fast_rewind, '이전 문장 (←)', -1),
      const MaterialDesktopPlayOrPauseButton(),
      _desktopSeekButton(Icons.fast_forward, '다음 문장 (→)', 1),
      const MaterialDesktopSkipNextButton(),
      const MaterialDesktopVolumeButton(),
      const MaterialDesktopPositionIndicator(),
      const Spacer(),
      const MaterialDesktopFullscreenButton(),
    ],
  );

  // 버튼이 포커스를 가져가면 Space/Enter가 재생/일시정지 대신 버튼을 누르게 된다
  Widget _desktopSeekButton(IconData icon, String tip, int direction) =>
      ExcludeFocus(
        child: Tooltip(
          message: tip,
          child: MaterialDesktopCustomButton(
            icon: Icon(icon),
            onPressed: () =>
                _seekSentence(direction, Duration(seconds: 10 * direction)),
          ),
        ),
      );

  /// 터치 기기(태블릿·휴대폰): YouTube처럼
  /// - 화면을 한 번 탭 → 화면이 어두워지며 조작 버튼 표시 (4초 뒤 숨김)
  /// - 가운데: ⏪10초 · 재생/일시정지 · 10초⏩
  /// - 아래: 시간 / 슬라이드 바 / 전체 화면
  /// - 왼쪽·오른쪽 두 번 탭: ±10초, 가로로 밀기: 이동
  late final _touchTheme = _touchControls(bottom: 8);

  /// 전체 화면: 화면 맨 아래는 시스템 제스처(위로 밀어 홈) 영역이라 슬라이드 바를 더 올린다
  late final _touchFullscreenTheme = _touchControls(bottom: 36);

  MaterialVideoControlsThemeData _touchControls({required double bottom}) =>
      MaterialVideoControlsThemeData(
        backdropColor: const Color(0x80000000),
        seekOnDoubleTap: true,
        seekGesture: true,
        displaySeekBar: true,
        visibleOnMount: _pinControls,
        controlsHoverDuration: _pinControls
            ? const Duration(hours: 1)
            : const Duration(seconds: 4),
        topButtonBar: [Expanded(child: _topBar())],
        primaryButtonBar: [
          _touchPlayArea(flex: 2, doubleTapSeconds: -10),
          MaterialCustomButton(
            icon: const Icon(Icons.replay_10),
            iconSize: 44,
            onPressed: () => _seekBy(const Duration(seconds: -10)),
          ),
          _touchPlayArea(flex: 1, doubleTapSeconds: -10),
          const MaterialPlayOrPauseButton(iconSize: 72),
          _touchPlayArea(flex: 1, doubleTapSeconds: 10),
          MaterialCustomButton(
            icon: const Icon(Icons.forward_10),
            iconSize: 44,
            onPressed: () => _seekBy(const Duration(seconds: 10)),
          ),
          _touchPlayArea(flex: 2, doubleTapSeconds: 10),
        ],
        bottomButtonBar: const [
          MaterialPositionIndicator(),
          Spacer(),
          MaterialFullscreenButton(),
        ],
        buttonBarButtonSize: 28,
        seekBarMargin: EdgeInsets.fromLTRB(16, 0, 16, bottom),
        seekBarHeight: 4,
        seekBarContainerHeight: 40, // 손가락으로 잡기 쉽게
        seekBarThumbSize: 16,
        seekBarPositionColor: const Color(0xFF80DEEA),
        seekBarThumbColor: const Color(0xFF80DEEA),
      );

  /// 터치 조작부가 보일 때 버튼 사이 빈 곳: 탭하면 재생/일시정지, 두 번 탭하면 이동.
  /// 조작부가 숨겨져 있으면 이 영역이 없어 탭이 조작부를 띄운다.
  Widget _touchPlayArea({required int flex, required int doubleTapSeconds}) =>
      Expanded(
        flex: flex,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _player.playOrPause,
          onDoubleTap: () => _seekBy(Duration(seconds: doubleTapSeconds)),
          child: const SizedBox.expand(),
        ),
      );

  /// 개발용: DUALCUE_PIN_CONTROLS=1 이면 조작부를 계속 띄운다 (화면 검증용)
  static final bool _pinControls =
      kDebugMode && Platform.environment['DUALCUE_PIN_CONTROLS'] == '1';

  /// 개발용: DUALCUE_TOUCH=1 이면 데스크톱에서 터치용 조작부를 확인한다
  static final bool _touch =
      Platform.isAndroid ||
      Platform.isIOS ||
      (kDebugMode && Platform.environment['DUALCUE_TOUCH'] == '1');

  /// 화면 밝기를 낮췄을 때 영상을 덮는 검은 막 (전체 화면에서도 바뀌도록 알림을 구독)
  Widget _dimLayer() => ValueListenableBuilder<double>(
    valueListenable: _screenBrightness,
    builder: (_, b, _) => b >= 1
        ? const SizedBox.shrink()
        : IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 1 - b),
              child: const SizedBox.expand(),
            ),
          ),
  );

  /// 상단 메뉴 묶음 사이 구분선
  static const _menuDivider = SizedBox(
    height: 24,
    child: VerticalDivider(width: 13, thickness: 1, color: Colors.white24),
  );

  /// 상단 메뉴. 기능별로 묶고, 창이 좁으면 왼쪽부터 가려지므로(가로 스크롤) 자주 쓰는
  /// 것을 오른쪽에 둔다: 자막 도구 | 자막 보기 | 재생 | 열기 | 설정
  /// 버튼이 포커스를 가져가면 Space/Enter가 버튼을 누르게 되므로 제외한다.
  Widget _menuActions() => ExcludeFocus(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'AI로 다시 번역',
          icon: const Icon(Icons.auto_awesome),
          onPressed: _job?.canRetranslate ?? false ? _retranslate : null,
        ),
        Builder(
          builder: (button) => IconButton(
            tooltip: '자막·번역 다시 만들기',
            icon: const Icon(Icons.restart_alt),
            onPressed: _job == null ? null : () => _showRegenMenu(button),
          ),
        ),
        _menuDivider,
        IconButton(
          tooltip: '원문 자막',
          icon: Icon(
            _view.showOriginal ? Icons.subtitles : Icons.subtitles_off,
          ),
          onPressed: () =>
              setState(() => _view.showOriginal = !_view.showOriginal),
        ),
        IconButton(
          tooltip: '번역 자막',
          icon: Icon(
            _view.showTranslation
                ? Icons.translate
                : Icons.g_translate_outlined,
          ),
          onPressed: () =>
              setState(() => _view.showTranslation = !_view.showTranslation),
        ),
        IconButton(
          tooltip: '학습 단어 (V)',
          icon: Icon(
            _settings.showVocab ? Icons.school : Icons.school_outlined,
            color: _settings.showVocab ? const Color(0xFF80DEEA) : null,
          ),
          onPressed: _toggleVocab,
        ),
        _menuDivider,
        IconButton(
          tooltip: _settings.repeatVideo ? '반복 재생 켜짐 (R)' : '반복 재생 꺼짐 (R)',
          icon: Icon(
            Icons.repeat_one,
            color: _settings.repeatVideo ? const Color(0xFF80DEEA) : null,
          ),
          onPressed: _toggleRepeat,
        ),
        _sentenceLoopButton(),
        IconButton(
          tooltip: '이전 영상 (P)',
          icon: const Icon(Icons.skip_previous),
          onPressed: _currentPath == null ? null : () => _skip(-1),
        ),
        IconButton(
          tooltip: '다음 영상 (N)',
          icon: const Icon(Icons.skip_next),
          onPressed: _currentPath == null ? null : () => _skip(1),
        ),
        IconButton(
          tooltip: _settings.autoPlayNext ? '연속 재생 켜짐' : '연속 재생 꺼짐',
          icon: Icon(
            _settings.autoPlayNext
                ? Icons.playlist_play
                : Icons.playlist_remove,
            color: _settings.autoPlayNext ? const Color(0xFF80DEEA) : null,
          ),
          onPressed: _toggleAutoPlayNext,
        ),
        _menuDivider,
        // YouTube는 yt-dlp가 필요해 데스크톱만
        if (_showYoutubeButton && hasDesktopTools)
          IconButton(
            tooltip: 'YouTube 열기',
            icon: const Icon(Icons.smart_display),
            onPressed: _loading ? null : _openYoutube,
          ),
        // TED 목록도 yt-dlp로 받는다 (데스크톱만)
        if (hasDesktopTools)
          IconButton(
            tooltip: '영어 강연·학습 채널 (TED·BBC·VOA)',
            icon: const Icon(Icons.record_voice_over),
            onPressed: _loading ? null : _openTed,
          ),
        IconButton(
          tooltip: '최근 재생목록',
          icon: const Icon(Icons.history),
          onPressed: _loading ? null : _showRecent,
        ),
        IconButton(
          tooltip: '동영상 열기',
          icon: const Icon(Icons.folder_open),
          onPressed: _loading ? null : _openFile,
        ),
        _menuDivider,
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
  );

  /// 영상 위 상단 줄 (제목·진행 상태·메뉴). 하단 조작부와 함께 나타나고 사라진다.
  /// 전체 화면은 별도 화면이라 setState가 닿지 않으므로 [_uiChanged]를 구독한다.
  Widget _topBar() => ListenableBuilder(
    listenable: _uiChanged,
    builder: (context, _) {
      // 영상을 열기 전에는 화면 위쪽 앱바에 같은 메뉴가 항상 보인다
      if (!_opened) return const SizedBox.shrink();
      final job = _job;
      final status = job?.status ?? '';
      final notice = job?.notice;
      final failed = job?.stage == JobStage.failed;
      TextStyle line(Color color) => TextStyle(
        color: color,
        fontSize: 12,
        decoration: TextDecoration.none,
      );
      return LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  if (status.isNotEmpty || notice != null)
                    Row(
                      children: [
                        if (status.isNotEmpty)
                          Flexible(
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: line(
                                failed
                                    ? Theme.of(context).colorScheme.error
                                    : Colors.white70,
                              ),
                            ),
                          ),
                        if (notice != null) ...[
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              notice,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: line(Colors.amber),
                            ),
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
            PlayCountBadge(info: _playInfo, onReset: _resetCount),
            // 폭이 좁으면 제목을 남기고 버튼 줄을 가로로 밀 수 있게 한다
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: _menuActions(),
              ),
            ),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    // 툴바 버튼 등 영상 밖에 포커스가 있어도 Space/Enter로 재생/일시정지
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: _opened
              ? null
              : AppBar(
                  title: Text(_title, overflow: TextOverflow.ellipsis),
                  actions: [_menuActions()],
                ),
          // Android 15+는 화면 끝까지 그리므로 아래 작업 표시줄·내비게이션 바를 피한다
          // (안 피하면 슬라이드 바·시간·자막 아래쪽이 작업 표시줄에 가려짐)
          body: SafeArea(
            top: _opened, // 앱바가 없으면 상단 상태 표시줄도 직접 피한다
            child: Stack(
              children: [
                // media_kit 내장 자막 렌더링은 끄고 자체 오버레이를 사용한다.
                MaterialVideoControlsTheme(
                  normal: _touchTheme,
                  fullscreen: _touchFullscreenTheme,
                  child: MaterialDesktopVideoControlsTheme(
                    normal: _controlsTheme,
                    fullscreen: _controlsTheme,
                    child: Video(
                      key: _videoKey,
                      controller: _controller,
                      subtitleViewConfiguration:
                          const SubtitleViewConfiguration(visible: false),
                      // controls 빌더는 전체 화면에서도 다시 쓰이므로 자막을 여기에 넣는다
                      controls: (state) => Stack(
                        children: [
                          // 화면 밝기 (데스크톱): 영상만 어둡게. 자막·조작부는 이 위에 그린다
                          if (!_touch) _dimLayer(),
                          if (_touch)
                            MaterialVideoControls(state)
                          else
                            MaterialDesktopVideoControls(state),
                          // 위/아래로 밀기: 오른쪽은 소리, 왼쪽은 밝기 (조작부 위에 겹침)
                          if (Platform.isAndroid) const VolumeDragLayer(),
                          // 상단 메뉴와 하단 조작부를 뺀 영상 영역의 클릭.
                          // 통과형이라 마우스를 올렸을 때 조작부도 그대로 나타난다
                          if (!_touch)
                            Positioned(
                              top: 56,
                              left: 0,
                              right: 0,
                              bottom: 84,
                              child: LayoutBuilder(
                                builder: (context, box) => Listener(
                                  behavior: HitTestBehavior.translucent,
                                  onPointerSignal: (e) =>
                                      _onWheel(e, box.maxWidth),
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTap: _onVideoClick,
                                  ),
                                ),
                              ),
                            ),
                          // 자막 상자가 클릭을 받도록 조작부 위에 둔다 (상자 밖은 통과)
                          LiveDualSubtitle(
                            position: _player.stream.position,
                            currentPosition: () => _player.state.position,
                            view: _view,
                            onTapCue: _copyCue,
                          ),
                          Positioned.fill(
                            child: Center(
                              child: ValueListenableBuilder(
                                valueListenable: _centerHint,
                                builder: (context, hint, _) =>
                                    hint ?? const SizedBox.shrink(),
                              ),
                            ),
                          ),
                          // 전체 화면 안내는 상단 줄과 겹치지 않게 그 아래에 둔다
                          Positioned(
                            top: 56,
                            left: 0,
                            right: 0,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ValueListenableBuilder(
                                  valueListenable: _flash,
                                  builder: (context, msg, _) => msg == null
                                      ? const SizedBox.shrink()
                                      : _OverlayMessage(msg),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 좌우 화살표로 이동할 때 화면 가운데에 잠깐 보여 주는 표시
class _SeekHint extends StatelessWidget {
  const _SeekHint({required this.forward, required this.label});

  final bool forward;
  final String label;

  @override
  Widget build(BuildContext context) {
    final children = [
      Icon(
        forward ? Icons.fast_forward : Icons.fast_rewind,
        color: Colors.white,
        size: 28,
      ),
      const SizedBox(width: 10),
      Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          decoration: TextDecoration.none,
        ),
      ),
    ];
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: forward ? children.reversed.toList() : children,
        ),
      ),
    );
  }
}

/// 전체 화면에서 잠깐 보여 주는 안내
class _OverlayMessage extends StatelessWidget {
  const _OverlayMessage(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          decoration: TextDecoration.none,
        ),
      ),
    ),
  );
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
