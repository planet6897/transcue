import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../source/ted_catalog.dart';
import 'resume.dart' show formatPosition;

/// 영어 강연·학습 채널(TED, TED-Ed, TEDx, BBC·VOA Learning English)에서 영상 고르기.
/// 위는 채널·검색, 왼쪽은 분류(최신 영상 + 채널 재생목록), 오른쪽은 영상.
/// 고른 영상의 YouTube ID를 돌려준다.
///
/// 자막이 없는 영상도 음성 인식·번역으로 이중 자막을 만들 수 있으므로 거르지 않는다.
class TedBrowserDialog extends StatefulWidget {
  const TedBrowserDialog({super.key, required this.catalog, this.watched});

  final TedCatalog catalog;

  /// 본 적 있는 영상인지 (재생 횟수 등). 목록에 표시만 한다.
  final Future<bool> Function(String id)? watched;

  @override
  State<TedBrowserDialog> createState() => _TedBrowserDialogState();
}

/// 분류 하나의 목록 상태 (분류를 오가도 다시 받지 않게 열려 있는 동안 기억한다)
class _FeedState {
  var videos = <TedVideo>[];

  /// 첫 페이지를 이번에 받았는지 (최신 강연은 그 전에 캐시만 보인다)
  var fresh = false;
  var reachedEnd = false;

  /// 다음 페이지를 받을 위치 (걸러 낸 항목·중복 때문에 videos.length와 다를 수 있다)
  var offset = 0;
  var loading = false;
  String? error;
}

class _TedBrowserDialogState extends State<TedBrowserDialog> {
  /// 지금 보는 채널 (다음에 열 때 이어서 보여 준다)
  var _channel = VideoChannel.ted;
  var _feed = TedFeed.latest;
  final _startedChannels = <String>{};

  /// 길이로 거른 영상이 이보다 적으면 다음 페이지를 알아서 불러온다 (최대 [_maxAutoLoad]개까지)
  static const _minFiltered = 10;
  static const _maxAutoLoad = 300;

  /// 정렬 (분류를 바꿔도 유지). 불러온 영상 안에서 정렬한다.
  var _sort = TedSort.original;

  /// 재생 시간 필터 (분류를 바꿔도 유지)
  var _length = TedLength.any;
  final _feeds = <TedFeed, _FeedState>{};

  /// 채널별 분류(재생목록)와 받는 중인 채널
  final _playlistsBy = <String, List<TedFeed>>{};
  final _playlistsLoadingFor = <String>{};
  List<TedFeed> get _playlists => _playlistsBy[_channel.id] ?? const [];
  bool get _playlistsLoading => _playlistsLoadingFor.contains(_channel.id);

  /// 검색해 본 것 (분류 목록 위에 보여 다시 고를 수 있게, 채널별로 최근 5개)
  final _searches = <TedFeed>[];

  final _watched = <String>{};
  final _checked = <String>{};
  final _scroll = ScrollController();
  final _query = TextEditingController();
  final _filter = TextEditingController();

  _FeedState get _state => _feeds.putIfAbsent(_feed, _FeedState.new);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _filter.addListener(() => setState(() {}));
    unawaited(_start());
  }

  Future<void> _start() async {
    final last = await widget.catalog.lastChannel();
    if (mounted) _switchChannel(last, remember: false);
  }

  /// 채널을 바꾼다. 받은 목록은 열려 있는 동안 채널별로 기억한다.
  void _switchChannel(VideoChannel c, {bool remember = true}) {
    // _feeds는 그리기만 해도 빈 항목이 생기므로 받기 시작한 채널을 따로 센다
    final first = _startedChannels.add(c.id);
    setState(() {
      _channel = c;
      _feed = TedFeed.latestOf(c);
      _filter.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (first) unawaited(_startLatest(c));
    if (!_playlistsBy.containsKey(c.id)) unawaited(_loadPlaylists(c));
    if (remember) unawaited(widget.catalog.saveLastChannel(c));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _query.dispose();
    _filter.dispose();
    super.dispose();
  }

  // ---- 분류 ----

  Future<void> _loadPlaylists(VideoChannel c) async {
    _playlistsBy[c.id] = const [];
    final cached = await widget.catalog.cachedPlaylists(c);
    if (!mounted) return;
    setState(() {
      _playlistsBy[c.id] = cached;
      _playlistsLoadingFor.add(c.id);
    });
    try {
      final fresh = await widget.catalog.fetchPlaylists(c);
      if (mounted && fresh.isNotEmpty) {
        setState(() => _playlistsBy[c.id] = fresh);
      }
    } on Exception catch (e) {
      debugPrint('${c.name} playlists failed: $e');
    } finally {
      if (mounted) setState(() => _playlistsLoadingFor.remove(c.id));
    }
  }

  void _select(TedFeed feed) {
    if (feed == _feed) return;
    setState(() => _feed = feed);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    final s = _state;
    if (!s.fresh && !s.loading) unawaited(_refresh(feed));
  }

  void _search() {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final feed = TedFeed.search(q, channel: _channel);
    setState(() {
      _searches
        ..remove(feed)
        ..insert(0, feed);
      final mine = _searches.where((f) => f.channel.id == _channel.id).toList();
      if (mine.length > 5) _searches.remove(mine.last);
    });
    _select(feed);
  }

  // ---- 영상 목록 ----

  Future<void> _startLatest(VideoChannel c) async {
    final latest = TedFeed.latestOf(c);
    final s = _feeds.putIfAbsent(latest, _FeedState.new);
    final cached = await widget.catalog.cached(c);
    if (!mounted) return;
    if (cached.isNotEmpty && s.videos.isEmpty) {
      setState(() => s.videos = cached);
      _checkWatched(cached);
    }
    await _refresh(latest);
  }

  void _checkWatched(List<TedVideo> videos) {
    final w = widget.watched;
    if (w == null) return;
    for (final v in videos) {
      if (!_checked.add(v.id)) continue;
      unawaited(
        w(v.id).then((yes) {
          if (yes && mounted) setState(() => _watched.add(v.id));
        }),
      );
    }
  }

  /// [feed]의 첫 페이지를 다시 받는다. 받는 동안 다른 분류로 옮겨도
  /// 결과는 [feed]의 상태에만 들어간다.
  Future<void> _refresh(TedFeed feed) async {
    final s = _feeds.putIfAbsent(feed, _FeedState.new);
    if (s.loading) return;
    setState(() {
      s.loading = true;
      s.error = null;
    });
    try {
      final page = await widget.catalog.fetch(feed);
      if (!mounted) return;
      setState(() {
        s.fresh = true;
        s.reachedEnd = page.isLast;
        if (feed.kind == TedFeedKind.latest) {
          // 최신 영상은 저장해 둔 목록 뒤를 이어 받는다 (캐시는 영상만 이어진 목록)
          s.videos = mergeLatest(page.videos, s.videos);
          s.offset = s.videos.length;
        } else {
          s.videos = page.videos;
          s.offset = page.received;
        }
      });
      _checkWatched(s.videos);
      if (feed.kind == TedFeedKind.latest) {
        unawaited(widget.catalog.save(s.videos, feed.channel));
      }
    } on Exception catch (e) {
      if (mounted) setState(() => s.error = '$e');
    } finally {
      if (mounted) setState(() => s.loading = false);
    }
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 600) unawaited(_loadMore(_feed));
  }

  Future<void> _loadMore(TedFeed feed) async {
    final s = _feeds.putIfAbsent(feed, _FeedState.new);
    // 첫 페이지를 받기 전에는 캐시 뒤를 이어 받으면 순서가 꼬일 수 있다
    if (!s.fresh || s.loading || s.reachedEnd) return;
    setState(() => s.loading = true);
    try {
      final page = await widget.catalog.fetch(feed, offset: s.offset);
      if (!mounted) return;
      setState(() {
        // 그사이 새 영상이 올라오면 같은 영상이 다시 올 수 있어 겹치는 것은 뺀다
        s.videos = appendNew(s.videos, page.videos);
        s.offset += page.received;
        s.reachedEnd = page.isLast;
      });
      _checkWatched(s.videos);
      if (feed.kind == TedFeedKind.latest) {
        unawaited(widget.catalog.save(s.videos, feed.channel));
      }
    } on Exception catch (e) {
      if (mounted) setState(() => s.error = '$e');
    } finally {
      if (mounted) setState(() => s.loading = false);
    }
  }

  String _detail(TedVideo v) => [
    ?v.speaker,
    if (v.duration case final d?) formatPosition(d),
    if (v.views case final n?) '조회수 ${formatViews(n)}',
    if (v.uploaded case final u?) formatAgo(u, DateTime.now().toUtc()),
    if (_watched.contains(v.id)) '본 영상',
  ].join(' · ');

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    // AlertDialog는 내용 폭을 고유 크기로 재서 창보다 커질 수 있어 크기를 직접 정한다
    const inset = 24.0;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(980.0, size.width - inset * 2);
    final height = math.min(680.0, size.height - inset * 2);
    final s = _state;
    return Dialog(
      insetPadding: const EdgeInsets.all(inset),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 8, 12),
              child: _header(s, compact: width < 600),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: math.min(260, width * 0.32),
                    child: _feedList(),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _videoPane(s)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(_FeedState s, {required bool compact}) => Row(
    children: [
      if (!compact) ...[_channelPicker(), const SizedBox(width: 24)],
      Expanded(
        child: TextField(
          controller: _query,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            isDense: true,
            hintText: compact
                ? '${_channel.name} 검색'
                : '${_channel.name}에서 검색 (영어: happiness, grammar …)',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: IconButton(
              tooltip: '검색',
              icon: const Icon(Icons.arrow_forward, size: 20),
              onPressed: _search,
            ),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      const SizedBox(width: 4),
      if (s.loading && !s.fresh)
        const Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      else
        IconButton(
          tooltip: '새로 고침',
          icon: const Icon(Icons.refresh),
          onPressed: () => _refresh(_feed),
        ),
      IconButton(
        tooltip: '닫기',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
    ],
  );

  /// 채널 고르기 (이름 + 짧은 설명)
  Widget _channelPicker() => DropdownButton<VideoChannel>(
    value: _channel,
    underline: const SizedBox.shrink(),
    style: Theme.of(context).textTheme.titleLarge,
    selectedItemBuilder: (_) => [
      for (final c in VideoChannel.all) Center(child: Text(c.name)),
    ],
    items: [
      for (final c in VideoChannel.all)
        DropdownMenuItem(
          value: c,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name, style: Theme.of(context).textTheme.titleSmall),
              Text(c.about, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
    ],
    onChanged: (c) {
      if (c != null && c.id != _channel.id) _switchChannel(c);
    },
  );

  Widget _feedTile(TedFeed f, {IconData? icon}) => ListTile(
    dense: true,
    selected: f == _feed,
    leading: icon == null ? null : Icon(icon, size: 20),
    title: Text(f.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    onTap: () => _select(f),
  );

  Widget _feedList() {
    final f = _filter.text.trim().toLowerCase();
    final playlists = f.isEmpty
        ? _playlists
        : _playlists.where((p) => p.title.toLowerCase().contains(f)).toList();
    return Column(
      children: [
        _feedTile(
          TedFeed.latestOf(_channel),
          icon: Icons.new_releases_outlined,
        ),
        for (final q in _searches)
          if (q.channel.id == _channel.id) _feedTile(q, icon: Icons.search),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _filter,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: '분류 ${_playlists.length}개에서 찾기',
              prefixIcon: const Icon(Icons.filter_list, size: 18),
              suffixIcon: _playlistsLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
          ),
        ),
        Expanded(
          child: playlists.isEmpty
              ? Center(
                  child: Text(
                    _playlistsLoading ? '분류를 받는 중…' : '분류가 없습니다',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              : ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (_, i) => _feedTile(playlists[i]),
                ),
        ),
      ],
    );
  }

  Widget _videoPane(_FeedState s) {
    final theme = Theme.of(context);
    final videos = sortVideos(s.videos.where(_length.accepts).toList(), _sort);
    final narrowed = _sort != TedSort.original || _length != TedLength.any;
    // 길이로 거르면 몇 개 안 남아 스크롤할 수 없으니 알아서 더 불러온다
    final searching =
        _length != TedLength.any &&
        videos.length < _minFiltered &&
        s.fresh &&
        !s.reachedEnd &&
        s.videos.length < _maxAutoLoad;
    if (searching && !s.loading) {
      final feed = _feed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadMore(feed));
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _feed.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              // 정렬은 지금까지 불러온 영상 안에서 한다 (스크롤하면 더 불러와 다시 정렬)
              if (narrowed && s.videos.isNotEmpty)
                Text(
                  _length == TedLength.any
                      ? '불러온 ${s.videos.length}개 중'
                      : '불러온 ${s.videos.length}개 중 ${videos.length}개',
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(width: 8),
              Tooltip(
                message: '재생 시간',
                child: DropdownButton<TedLength>(
                  value: _length,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  icon: const Icon(Icons.timer_outlined, size: 18),
                  style: theme.textTheme.bodyMedium,
                  items: [
                    for (final o in TedLength.values)
                      DropdownMenuItem(value: o, child: Text(o.label)),
                  ],
                  onChanged: (o) {
                    if (o == null) return;
                    setState(() => _length = o);
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '정렬',
                child: DropdownButton<TedSort>(
                  value: _sort,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  icon: const Icon(Icons.sort, size: 18),
                  style: theme.textTheme.bodyMedium,
                  items: [
                    for (final o in TedSort.values)
                      DropdownMenuItem(value: o, child: Text(o.label)),
                  ],
                  onChanged: (o) {
                    if (o == null) return;
                    setState(() => _sort = o);
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                ),
              ),
            ],
          ),
        ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '목록을 받지 못했습니다: ${s.error}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Expanded(
          child: videos.isEmpty
              ? Center(
                  child: Text(
                    s.loading || searching
                        ? '목록을 받는 중…'
                        : s.error != null
                        ? ''
                        : s.videos.isNotEmpty
                        ? '불러온 ${s.videos.length}개 중 ${_length.label} 영상이 없습니다'
                        : '영상이 없습니다',
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  itemCount: videos.length + 1,
                  itemBuilder: (context, i) {
                    if (i == videos.length) {
                      return s.loading && s.fresh
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : const SizedBox(height: 16);
                    }
                    return _videoTile(videos[i]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _videoTile(TedVideo v) => ListTile(
    leading: ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        v.thumbnailUrl,
        width: 112,
        height: 63,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox(
          width: 112,
          height: 63,
          child: Icon(Icons.smart_display),
        ),
      ),
    ),
    title: Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(_detail(v), maxLines: 1, overflow: TextOverflow.ellipsis),
    onTap: () => Navigator.pop(context, v.id),
  );
}
