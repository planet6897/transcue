import 'dart:convert';
import 'dart:io';

import 'yt_dlp.dart';

/// TED 공식 YouTube 채널.
///
/// TED.com은 자동 접근을 막고 있어(403 "automated access to TED.com is not permitted")
/// YouTube 채널을 쓴다. TED 번역 봉사자 자막도 YouTube에 함께 올라간다.
const tedChannelUrl = 'https://www.youtube.com/@TED';

enum TedFeedKind { latest, playlist, search }

/// 영상 목록을 어디서 가져올지: 최신 업로드 / TED 재생목록(분류) / 채널 검색
class TedFeed {
  const TedFeed._(this.kind, this.key, this.title);

  static const latest = TedFeed._(TedFeedKind.latest, '', '최신 강연');

  /// TED 채널의 재생목록 하나 ("Best TED Talks on psychology" 등)
  const TedFeed.playlist(String id, String title)
    : this._(TedFeedKind.playlist, id, title);

  /// TED 채널 안에서 검색 (관련도순)
  TedFeed.search(String query)
    : this._(TedFeedKind.search, query.trim(), '“${query.trim()}” 검색 결과');

  final TedFeedKind kind;

  /// 재생목록 ID 또는 검색어
  final String key;
  final String title;

  String get url => switch (kind) {
    TedFeedKind.latest => '$tedChannelUrl/videos',
    TedFeedKind.playlist => 'https://www.youtube.com/playlist?list=$key',
    TedFeedKind.search =>
      '$tedChannelUrl/search?query=${Uri.encodeQueryComponent(key)}',
  };

  @override
  bool operator ==(Object other) =>
      other is TedFeed && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);

  /// `yt-dlp --flat-playlist`로 받은 채널 재생목록 항목. 재생목록이 아니면 null.
  static TedFeed? playlistFromEntry(Map<String, dynamic> e) {
    final id = e['id'], title = e['title'];
    if (id is! String || title is! String || !id.startsWith('PL')) return null;
    return TedFeed.playlist(id, title.trim());
  }
}

/// TED 영상 하나
class TedVideo {
  const TedVideo({
    required this.id,
    required this.title,
    this.speaker,
    this.duration,
    this.views,
  });

  /// YouTube 동영상 ID
  final String id;

  /// 강연 제목 (YouTube 제목에서 "| 강연자 | TED"를 뗀 것)
  final String title;
  final String? speaker;
  final Duration? duration;
  final int? views;

  String get thumbnailUrl => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';

  /// `yt-dlp --flat-playlist` 항목에서 만든다. 영상이 아니면 null.
  static TedVideo? fromEntry(Map<String, dynamic> e) {
    final id = e['id'];
    final raw = e['title'];
    if (id is! String || raw is! String || id.length != 11) return null;
    final (title, speaker) = splitTedTitle(raw);
    final d = e['duration'];
    final v = e['view_count'];
    return TedVideo(
      id: id,
      title: title,
      speaker: speaker,
      duration: d is num ? Duration(seconds: d.round()) : null,
      views: v is num ? v.toInt() : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (speaker != null) 'speaker': speaker,
    if (duration != null) 'duration': duration!.inSeconds,
    if (views != null) 'views': views,
  };

  static TedVideo? fromJson(Map<String, dynamic> j) {
    final id = j['id'], title = j['title'];
    if (id is! String || title is! String) return null;
    final d = j['duration'], v = j['views'];
    return TedVideo(
      id: id,
      title: title,
      speaker: j['speaker'] as String?,
      duration: d is int ? Duration(seconds: d) : null,
      views: v is int ? v : null,
    );
  }
}

/// YouTube 제목에서 강연자를 뗀다. 형식이 다르면 제목 그대로.
/// - "제목 | 강연자 | TED" (요즘 형식, TEDx·TED Countdown 등 포함)
/// - "제목 | 강연자" (예전 형식)
/// - "제목 | TED…" (강연자 없음)
(String, String?) splitTedTitle(String raw) {
  final parts = raw.split(' | ').map((s) => s.trim()).toList();
  bool isTed(String s) => s.startsWith('TED');
  if (parts.length >= 3 && isTed(parts.last)) {
    return (
      parts.sublist(0, parts.length - 2).join(' | '),
      parts[parts.length - 2],
    );
  }
  if (parts.length == 2 && parts.every((p) => p.isNotEmpty)) {
    return isTed(parts.last) ? (parts.first, null) : (parts.first, parts.last);
  }
  return (raw.trim(), null);
}

/// 새로 받은 최신 페이지 [fresh] 뒤에 이전 목록 [old]를 붙인다 (겹치는 영상은 한 번만).
///
/// 둘이 하나도 겹치지 않으면 그 사이에 빠진 영상이 있을 수 있어 [old]를 버린다
/// (오래된 캐시를 이어 붙이면 다음 페이지 위치도 어긋난다). 단 [fresh]가 비었으면 [old].
List<TedVideo> mergeLatest(List<TedVideo> fresh, List<TedVideo> old) {
  if (fresh.isEmpty) return old;
  final seen = {for (final v in fresh) v.id};
  if (!old.any((v) => seen.contains(v.id))) return fresh;
  return appendNew(fresh, old);
}

/// [list] 뒤에 [more]에서 아직 없는 영상만 붙인다 (다음 페이지)
List<TedVideo> appendNew(List<TedVideo> list, List<TedVideo> more) {
  final seen = {for (final v in list) v.id};
  return [...list, ...more.where((v) => seen.add(v.id))];
}

/// 조회수를 짧게: 950 / 1.2천 / 3.4만 / 120만
String formatViews(int n) {
  String one(double x) {
    final s = x.toStringAsFixed(x < 10 ? 1 : 0);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (n >= 100000000) return '${one(n / 100000000)}억';
  if (n >= 10000) return '${one(n / 10000)}만';
  if (n >= 1000) return '${one(n / 1000)}천';
  return '$n';
}

/// TED 영상 목록. 최신 영상과 분류(재생목록) 목록은 [cacheFile]에 저장해 바로 보여 준다.
class TedCatalog {
  TedCatalog(this.ytDlp, this.cacheFile);

  final YtDlp ytDlp;
  final File cacheFile;

  static const pageSize = 30;

  /// 분류로 보여 줄 재생목록 최대 개수
  static const maxPlaylists = 200;

  /// 캐시에 남기는 최신 영상 최대 개수
  static const _keep = 300;

  Future<Map<String, dynamic>> _readCache() async {
    try {
      final j = jsonDecode(await cacheFile.readAsString());
      return j is Map<String, dynamic> ? j : {};
    } on Object {
      return {};
    }
  }

  /// 저장을 차례로 (최신 영상과 분류를 한 파일에 쓰므로 동시에 쓰면 한쪽이 사라진다)
  Future<void> _writing = Future.value();

  Future<void> _writeCache(String key, Object value) => _writing = _writing
      .then((_) async {
        final j = await _readCache()
          ..[key] = value;
        await cacheFile.parent.create(recursive: true);
        await cacheFile.writeAsString(jsonEncode(j));
      })
      .catchError((Object _) {});

  static List<Map<String, dynamic>> _maps(Object? l) =>
      l is List ? l.whereType<Map<String, dynamic>>().toList() : const [];

  /// 저장된 최신 영상
  Future<List<TedVideo>> cached() async => [
    for (final e in _maps((await _readCache())['videos']))
      ?TedVideo.fromJson(e),
  ];

  Future<void> save(List<TedVideo> videos) =>
      _writeCache('videos', videos.take(_keep).map((v) => v.toJson()).toList());

  /// 저장된 분류(재생목록)
  Future<List<TedFeed>> cachedPlaylists() async => [
    for (final e in _maps((await _readCache())['playlists']))
      ?TedFeed.playlistFromEntry(e),
  ];

  /// TED 채널의 재생목록을 받아 저장한다
  Future<List<TedFeed>> fetchPlaylists() async {
    final j = await ytDlp.listPlaylist(
      '$tedChannelUrl/playlists',
      start: 1,
      end: maxPlaylists,
    );
    final out = <TedFeed>[];
    final seen = <String>{};
    for (final e in _maps(j['entries'])) {
      final f = TedFeed.playlistFromEntry(e);
      if (f != null && seen.add(f.key)) out.add(f);
    }
    await _writeCache('playlists', [
      for (final f in out) {'id': f.key, 'title': f.title},
    ]);
    return out;
  }

  /// [feed]의 [offset]개 다음부터 한 페이지
  Future<TedPage> fetch(TedFeed feed, {int offset = 0}) async {
    final j = await ytDlp.listPlaylist(
      feed.url,
      start: offset + 1,
      end: offset + pageSize,
    );
    final entries = _maps(j['entries']);
    return TedPage([
      for (final e in entries) ?TedVideo.fromEntry(e),
    ], entries.length);
  }
}

/// 한 페이지. 검색 결과에는 재생목록·채널도 섞여 있어 [videos]가 [received]보다 적을 수 있다.
class TedPage {
  const TedPage(this.videos, this.received);

  final List<TedVideo> videos;

  /// 걸러 내기 전 항목 수 (다음 페이지 위치·마지막 페이지 판단용)
  final int received;

  bool get isLast => received < TedCatalog.pageSize;
}
