import 'dart:convert';
import 'dart:io';

import 'youtube_backend.dart';

/// YouTube 제목에서 강연자를 떼는 방식
enum TitleStyle {
  /// "제목 | 강연자 | TED" (TED, TEDx)
  ted,

  /// "제목 - 강연자" (TED-Ed)
  dash,

  /// 강연자 없이 제목만 (BBC·VOA Learning English)
  plain,
}

/// 영어 강연·학습용 YouTube 채널.
///
/// TED.com은 자동 접근을 막고 있어(403 "automated access to TED.com is not permitted")
/// YouTube 채널을 쓴다. TED 번역 봉사자 자막도 YouTube에 함께 올라간다.
class VideoChannel {
  const VideoChannel({
    required this.id,
    required this.name,
    required this.handle,
    required this.about,
    this.titleStyle = TitleStyle.plain,
  });

  /// 캐시·설정에 쓰는 고유 이름
  final String id;
  final String name;

  /// YouTube 채널 핸들 (@ 뒤)
  final String handle;

  /// 채널 고르는 메뉴에 붙는 짧은 설명
  final String about;
  final TitleStyle titleStyle;

  String get url => 'https://www.youtube.com/@$handle';

  static const ted = VideoChannel(
    id: 'ted',
    name: 'TED',
    handle: 'TED',
    about: '강연',
    titleStyle: TitleStyle.ted,
  );

  static const all = [
    ted,
    VideoChannel(
      id: 'ted-ed',
      name: 'TED-Ed',
      handle: 'TEDEd',
      about: '5분 내외 애니메이션 강의',
      titleStyle: TitleStyle.dash,
    ),
    VideoChannel(
      id: 'tedx',
      name: 'TEDx Talks',
      handle: 'TEDx',
      about: '세계 각지 강연',
      titleStyle: TitleStyle.ted,
    ),
    VideoChannel(
      id: 'bbc-le',
      name: 'BBC Learning English',
      handle: 'bbclearningenglish',
      about: '영어 학습 (영국 영어)',
    ),
    VideoChannel(
      id: 'voa-le',
      name: 'VOA Learning English',
      handle: 'VOALearningEnglish',
      about: '쉽고 느린 영어 (미국 영어)',
    ),
  ];

  static VideoChannel byId(String? id) =>
      all.firstWhere((c) => c.id == id, orElse: () => ted);
}

/// TED 채널 주소
const tedChannelUrl = 'https://www.youtube.com/@TED';

enum TedFeedKind { latest, playlist, search }

/// 영상 목록을 어디서 가져올지: 채널의 최신 업로드 / 재생목록(분류) / 채널 안 검색
class TedFeed {
  const TedFeed._(this.kind, this.key, this.title, this.channel);

  /// TED 채널의 최신 영상
  static const latest = TedFeed.latestOf(VideoChannel.ted);

  /// [channel]의 최신 업로드
  const TedFeed.latestOf(VideoChannel channel)
    : this._(TedFeedKind.latest, '', '최신 영상', channel);

  /// 채널의 재생목록 하나 ("Best TED Talks on psychology" 등)
  const TedFeed.playlist(
    String id,
    String title, {
    VideoChannel channel = VideoChannel.ted,
  }) : this._(TedFeedKind.playlist, id, title, channel);

  /// 채널 안에서 검색 (관련도순)
  TedFeed.search(String query, {VideoChannel channel = VideoChannel.ted})
    : this._(
        TedFeedKind.search,
        query.trim(),
        '“${query.trim()}” 검색 결과',
        channel,
      );

  final TedFeedKind kind;

  /// 재생목록 ID 또는 검색어
  final String key;
  final String title;
  final VideoChannel channel;

  String get url => switch (kind) {
    TedFeedKind.latest => '${channel.url}/videos',
    TedFeedKind.playlist => 'https://www.youtube.com/playlist?list=$key',
    TedFeedKind.search =>
      '${channel.url}/search?query=${Uri.encodeQueryComponent(key)}',
  };

  @override
  bool operator ==(Object other) =>
      other is TedFeed &&
      other.kind == kind &&
      other.key == key &&
      other.channel.id == channel.id;

  @override
  int get hashCode => Object.hash(kind, key, channel.id);

  /// `yt-dlp --flat-playlist`로 받은 채널 재생목록 항목. 재생목록이 아니면 null.
  static TedFeed? playlistFromEntry(
    Map<String, dynamic> e, {
    VideoChannel channel = VideoChannel.ted,
  }) {
    final id = e['id'], title = e['title'];
    if (id is! String || title is! String || !id.startsWith('PL')) return null;
    return TedFeed.playlist(id, title.trim(), channel: channel);
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
    this.uploaded,
  });

  /// YouTube 동영상 ID
  final String id;

  /// 강연 제목 (YouTube 제목에서 "| 강연자 | TED"를 뗀 것)
  final String title;
  final String? speaker;
  final Duration? duration;
  final int? views;

  /// 올린 날 (목록의 "3주 전" 같은 표시로 어림한 값, 하루 단위)
  final DateTime? uploaded;

  String get thumbnailUrl => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';

  /// `yt-dlp --flat-playlist` 항목에서 만든다. 영상이 아니면 null.
  static TedVideo? fromEntry(
    Map<String, dynamic> e, {
    TitleStyle style = TitleStyle.ted,
  }) {
    final id = e['id'];
    final raw = e['title'];
    if (id is! String || raw is! String || id.length != 11) return null;
    final (title, speaker) = splitTitle(raw, style);
    final d = e['duration'];
    final v = e['view_count'];
    final t = e['timestamp'];
    return TedVideo(
      id: id,
      title: title,
      speaker: speaker,
      duration: d is num ? Duration(seconds: d.round()) : null,
      views: v is num ? v.toInt() : null,
      uploaded: t is num
          ? DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000, isUtc: true)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (speaker != null) 'speaker': speaker,
    if (duration != null) 'duration': duration!.inSeconds,
    if (views != null) 'views': views,
    if (uploaded != null) 'uploaded': uploaded!.millisecondsSinceEpoch ~/ 1000,
  };

  static TedVideo? fromJson(Map<String, dynamic> j) {
    final id = j['id'], title = j['title'];
    if (id is! String || title is! String) return null;
    final d = j['duration'], v = j['views'], u = j['uploaded'];
    return TedVideo(
      id: id,
      title: title,
      speaker: j['speaker'] as String?,
      duration: d is int ? Duration(seconds: d) : null,
      views: v is int ? v : null,
      uploaded: u is int
          ? DateTime.fromMillisecondsSinceEpoch(u * 1000, isUtc: true)
          : null,
    );
  }
}

/// 채널의 제목 형식에 맞춰 강연자를 뗀다
(String, String?) splitTitle(String raw, TitleStyle style) => switch (style) {
  TitleStyle.ted => splitTedTitle(raw),
  TitleStyle.dash => splitDashTitle(raw),
  TitleStyle.plain => (raw.trim(), null),
};

/// "제목 - 강연자" (TED-Ed). 마지막 " - " 뒤가 사람 이름처럼 짧을 때만 뗀다.
(String, String?) splitDashTitle(String raw) {
  final t = raw.trim();
  final i = t.lastIndexOf(' - ');
  if (i <= 0) return (t, null);
  final name = t.substring(i + 3).trim();
  final looksLikeName =
      name.isNotEmpty &&
      name.split(RegExp(r'\s+')).length <= 6 &&
      !name.contains('?') &&
      !name.contains(':');
  return looksLikeName ? (t.substring(0, i).trim(), name) : (t, null);
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

/// 목록 정렬
enum TedSort {
  /// 받은 순서 그대로 (최신 강연은 최신순, 검색은 관련도순, 분류는 재생목록 순서)
  original('기본 순서'),
  views('조회수 높은 순'),
  recent('최근 올라온 순'),
  shortest('짧은 순'),
  longest('긴 순');

  const TedSort(this.label);
  final String label;
}

/// [videos]를 [sort]대로 정렬한 새 목록. 값이 없는 영상은 뒤로, 같으면 원래 순서대로.
List<TedVideo> sortVideos(List<TedVideo> videos, TedSort sort) {
  if (sort == TedSort.original) return videos;
  // 큰 값부터 보여 주므로 짧은 순은 길이에 -를 붙인다
  int? key(TedVideo v) => switch (sort) {
    TedSort.views => v.views,
    TedSort.recent => v.uploaded?.millisecondsSinceEpoch,
    TedSort.shortest => v.duration == null ? null : -v.duration!.inSeconds,
    TedSort.longest => v.duration?.inSeconds,
    TedSort.original => null,
  };
  final indexed = [for (var i = 0; i < videos.length; i++) (i, videos[i])];
  indexed.sort((a, b) {
    final ka = key(a.$2), kb = key(b.$2);
    if (ka != kb) {
      if (ka == null) return 1;
      if (kb == null) return -1;
      return kb.compareTo(ka); // 큰 것(많이 본·최근·긴)부터
    }
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, v) in indexed) v];
}

/// 재생 시간으로 거르기
enum TedLength {
  any('모든 길이', null, null),
  short('5분 이하', null, Duration(minutes: 5)),
  medium('5~15분', Duration(minutes: 5), Duration(minutes: 15)),
  long('15분 이상', Duration(minutes: 15), null);

  const TedLength(this.label, this.min, this.max);
  final String label;

  /// [min] 초과 ~ [max] 이하 (경계 5분·15분은 짧은 쪽에 넣는다)
  final Duration? min;
  final Duration? max;

  /// 길이를 모르는 영상은 '모든 길이'에서만 보인다
  bool accepts(TedVideo v) {
    if (this == any) return true;
    final d = v.duration;
    if (d == null) return false;
    return (min == null || d > min!) && (max == null || d <= max!);
  }
}

/// 올린 날을 짧게: 오늘 / 어제 / 3일 전 / 2주 전 / 5개월 전 / 3년 전
String formatAgo(DateTime uploaded, DateTime now) {
  final days = now.difference(uploaded).inDays;
  if (days < 1) return '오늘';
  if (days < 2) return '어제';
  if (days < 7) return '$days일 전';
  if (days < 30) return '${days ~/ 7}주 전';
  if (days < 365) return '${days ~/ 30}개월 전';
  return '${days ~/ 365}년 전';
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

  /// 데스크톱 yt-dlp 또는 Android 순수 Dart
  final YoutubeBackend ytDlp;
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

  /// 캐시 키. TED는 채널을 나누기 전 이름을 그대로 써서 기존 캐시를 살린다.
  static String _key(VideoChannel c, String what) =>
      c.id == VideoChannel.ted.id ? what : '${c.id}.$what';

  /// 마지막으로 본 채널
  Future<VideoChannel> lastChannel() async =>
      VideoChannel.byId((await _readCache())['channel'] as String?);

  Future<void> saveLastChannel(VideoChannel c) => _writeCache('channel', c.id);

  /// 저장된 최신 영상
  Future<List<TedVideo>> cached([
    VideoChannel channel = VideoChannel.ted,
  ]) async => [
    for (final e in _maps((await _readCache())[_key(channel, 'videos')]))
      ?TedVideo.fromJson(e),
  ];

  Future<void> save(
    List<TedVideo> videos, [
    VideoChannel channel = VideoChannel.ted,
  ]) => _writeCache(
    _key(channel, 'videos'),
    videos.take(_keep).map((v) => v.toJson()).toList(),
  );

  /// 저장된 분류(재생목록)
  Future<List<TedFeed>> cachedPlaylists([
    VideoChannel channel = VideoChannel.ted,
  ]) async => [
    for (final e in _maps((await _readCache())[_key(channel, 'playlists')]))
      ?TedFeed.playlistFromEntry(e, channel: channel),
  ];

  /// 채널의 재생목록을 받아 저장한다
  Future<List<TedFeed>> fetchPlaylists([
    VideoChannel channel = VideoChannel.ted,
  ]) async {
    final j = await ytDlp.listPlaylist(
      '${channel.url}/playlists',
      start: 1,
      end: maxPlaylists,
    );
    final out = <TedFeed>[];
    final seen = <String>{};
    for (final e in _maps(j['entries'])) {
      final f = TedFeed.playlistFromEntry(e, channel: channel);
      if (f != null && seen.add(f.key)) out.add(f);
    }
    await _writeCache(_key(channel, 'playlists'), [
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
      for (final e in entries)
        ?TedVideo.fromEntry(e, style: feed.channel.titleStyle),
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
