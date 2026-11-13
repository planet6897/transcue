import 'dart:convert';
import 'dart:io';

import 'yt_dlp.dart';

/// TED 공식 YouTube 채널의 최신 업로드 (최신순).
///
/// TED.com은 자동 접근을 막고 있어(403 "automated access to TED.com is not permitted")
/// YouTube 채널을 쓴다. TED 번역 봉사자 자막도 YouTube에 함께 올라간다.
const tedChannelVideosUrl = 'https://www.youtube.com/@TED/videos';

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

/// "제목 | 강연자 | TED" → (제목, 강연자). 형식이 다르면 제목 그대로.
(String, String?) splitTedTitle(String raw) {
  final parts = raw.split(' | ').map((s) => s.trim()).toList();
  if (parts.length >= 3 && parts.last.startsWith('TED')) {
    return (
      parts.sublist(0, parts.length - 2).join(' | '),
      parts[parts.length - 2],
    );
  }
  if (parts.length == 2 && parts.last.startsWith('TED')) {
    return (parts.first, null);
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

/// TED 최신 영상 목록. 마지막으로 받은 목록을 [cacheFile]에 저장해 바로 보여 준다.
class TedCatalog {
  TedCatalog(this.ytDlp, this.cacheFile);

  final YtDlp ytDlp;
  final File cacheFile;

  static const pageSize = 30;

  /// 캐시에 남기는 최대 개수
  static const _keep = 300;

  Future<List<TedVideo>> cached() async {
    try {
      final j = jsonDecode(await cacheFile.readAsString());
      return [
        for (final e in (j['videos'] as List).cast<Map<String, dynamic>>())
          ?TedVideo.fromJson(e),
      ];
    } on Object {
      return const [];
    }
  }

  /// [offset]개 다음부터 한 페이지 (0 = 최신)
  Future<List<TedVideo>> fetch({int offset = 0}) async {
    final j = await ytDlp.listPlaylist(
      tedChannelVideosUrl,
      start: offset + 1,
      end: offset + pageSize,
    );
    final entries = (j['entries'] as List? ?? const [])
        .whereType<Map<String, dynamic>>();
    return [for (final e in entries) ?TedVideo.fromEntry(e)];
  }

  Future<void> save(List<TedVideo> videos) async {
    final list = videos.take(_keep).map((v) => v.toJson()).toList();
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsString(jsonEncode({'videos': list}));
  }
}
