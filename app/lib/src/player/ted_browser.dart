import 'dart:async';

import 'package:flutter/material.dart';

import '../source/ted_catalog.dart';
import 'resume.dart' show formatPosition;

/// TED 최신 영상 목록. 고른 영상의 YouTube ID를 돌려준다.
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

class _TedBrowserDialogState extends State<TedBrowserDialog> {
  var _videos = <TedVideo>[];
  final _watched = <String>{};
  final _scroll = ScrollController();

  /// 최신 페이지를 받는 중 / 다음 페이지를 받는 중
  var _refreshing = false;
  var _loadingMore = false;

  /// 이번에 최신 페이지를 받았는지 (그 전에는 캐시만 보이는 상태)
  var _fresh = false;
  var _reachedEnd = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_start());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final cached = await widget.catalog.cached();
    if (!mounted) return;
    if (cached.isNotEmpty) _show(cached);
    await _refresh();
  }

  void _show(List<TedVideo> videos) {
    setState(() => _videos = videos);
    final w = widget.watched;
    if (w == null) return;
    for (final v in videos) {
      if (_watched.contains(v.id)) continue;
      unawaited(
        w(v.id).then((yes) {
          if (yes && mounted) setState(() => _watched.add(v.id));
        }),
      );
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final page = await widget.catalog.fetch();
      if (!mounted) return;
      _fresh = true;
      _reachedEnd = page.length < TedCatalog.pageSize;
      _show(mergeLatest(page, _videos));
      unawaited(widget.catalog.save(_videos));
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 600) unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    // 최신 페이지를 받기 전에는 캐시 뒤를 이어 받으면 순서가 꼬일 수 있다
    if (!_fresh || _loadingMore || _refreshing || _reachedEnd) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.catalog.fetch(offset: _videos.length);
      if (!mounted) return;
      final before = _videos.length;
      _show(appendNew(_videos, page));
      // 그사이 새 영상이 올라오면 같은 영상이 다시 올 수 있다. 하나도 늘지 않으면 끝.
      _reachedEnd =
          page.length < TedCatalog.pageSize || _videos.length == before;
      unawaited(widget.catalog.save(_videos));
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  String _detail(TedVideo v) => [
    ?v.speaker,
    if (v.duration case final d?) formatPosition(d),
    if (v.views case final n?) '조회수 ${formatViews(n)}',
    if (_watched.contains(v.id)) '본 영상',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final busy = _refreshing && _videos.isEmpty;
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('TED 최신 강연')),
          if (_refreshing)
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              tooltip: '새로 고침',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 640,
        height: 520,
        child: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  '목록을 받지 못했습니다: $_error',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: busy
                  ? const Center(child: Text('TED 목록을 받는 중…'))
                  : _videos.isEmpty
                  ? const Center(child: Text('영상이 없습니다'))
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: _videos.length + 1,
                      itemBuilder: (context, i) {
                        if (i == _videos.length) {
                          return _loadingMore
                              ? const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              : const SizedBox(height: 16);
                        }
                        final v = _videos[i];
                        return ListTile(
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
                          title: Text(
                            v.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _detail(v),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.pop(context, v.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
