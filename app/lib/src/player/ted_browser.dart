import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../source/ted_catalog.dart';
import 'resume.dart' show formatPosition;

/// TED 강연 고르기: 왼쪽은 분류(최신 강연 + TED 재생목록), 오른쪽은 영상, 위는 검색.
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
  var _feed = TedFeed.latest;
  final _feeds = <TedFeed, _FeedState>{};
  var _playlists = <TedFeed>[];
  var _playlistsLoading = false;

  /// 검색해 본 것 (분류 목록 위에 보여 다시 고를 수 있게)
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
    unawaited(_startLatest());
    unawaited(_loadPlaylists());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _query.dispose();
    _filter.dispose();
    super.dispose();
  }

  // ---- 분류 ----

  Future<void> _loadPlaylists() async {
    final cached = await widget.catalog.cachedPlaylists();
    if (!mounted) return;
    setState(() {
      _playlists = cached;
      _playlistsLoading = true;
    });
    try {
      final fresh = await widget.catalog.fetchPlaylists();
      if (mounted && fresh.isNotEmpty) setState(() => _playlists = fresh);
    } on Exception catch (e) {
      debugPrint('TED playlists failed: $e');
    } finally {
      if (mounted) setState(() => _playlistsLoading = false);
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
    final feed = TedFeed.search(q);
    setState(() {
      _searches
        ..remove(feed)
        ..insert(0, feed);
      if (_searches.length > 5) _searches.removeLast();
    });
    _select(feed);
  }

  // ---- 영상 목록 ----

  Future<void> _startLatest() async {
    final cached = await widget.catalog.cached();
    if (!mounted) return;
    final s = _feeds.putIfAbsent(TedFeed.latest, _FeedState.new);
    if (cached.isNotEmpty && s.videos.isEmpty) {
      setState(() => s.videos = cached);
      _checkWatched(cached);
    }
    await _refresh(TedFeed.latest);
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
        if (feed == TedFeed.latest) {
          // 최신 영상은 저장해 둔 목록 뒤를 이어 받는다 (캐시는 영상만 이어진 목록)
          s.videos = mergeLatest(page.videos, s.videos);
          s.offset = s.videos.length;
        } else {
          s.videos = page.videos;
          s.offset = page.received;
        }
      });
      _checkWatched(s.videos);
      if (feed == TedFeed.latest) unawaited(widget.catalog.save(s.videos));
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
      if (feed == TedFeed.latest) unawaited(widget.catalog.save(s.videos));
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
      if (!compact) ...[
        Text('TED 강연', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(width: 24),
      ],
      Expanded(
        child: TextField(
          controller: _query,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            isDense: true,
            hintText: compact
                ? 'TED 검색 (영어)'
                : 'TED 강연 검색 (영어: happiness, leadership …)',
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
        _feedTile(TedFeed.latest, icon: Icons.new_releases_outlined),
        for (final q in _searches) _feedTile(q, icon: Icons.search),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            _feed.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
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
          child: s.videos.isEmpty
              ? Center(
                  child: Text(
                    s.loading
                        ? '목록을 받는 중…'
                        : s.error != null
                        ? ''
                        : '영상이 없습니다',
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  itemCount: s.videos.length + 1,
                  itemBuilder: (context, i) {
                    if (i == s.videos.length) {
                      return s.loading && s.fresh
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : const SizedBox(height: 16);
                    }
                    return _videoTile(s.videos[i]);
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
