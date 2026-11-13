import 'dart:convert';
import 'dart:io';

/// YouTube 웹 내부 API(InnerTube `browse`)로 채널·재생목록·검색 목록을 받는다.
///
/// Android처럼 yt-dlp가 없는 곳에서 쓴다. yt-dlp가 같은 API를 쓰므로 결과를
/// yt-dlp `--flat-playlist -J`의 `entries`와 같은 모양으로 돌려준다
/// (id, title, duration, view_count, timestamp). 그래서 목록을 쓰는 쪽(TedCatalog)은
/// 어느 쪽에서 받았는지 신경 쓰지 않는다.

/// 응답 한 번에서 읽은 항목과 다음 페이지 토큰
class InnertubePage {
  const InnertubePage(this.entries, this.continuation);
  final List<Map<String, dynamic>> entries;
  final String? continuation;
}

/// 목록이 아닌 곳(댓글 패널·머리글 등)에도 항목·토큰이 있어 건너뛴다
const _skipKeys = {
  'engagementPanels',
  'engagementPanel',
  'header',
  'topbar',
  'sidebar',
  'microformat',
  'frameworkUpdates',
};

/// browse 응답(처음 또는 다음 페이지)에서 영상·재생목록 항목과 다음 페이지 토큰을 읽는다.
/// [now]: "3 weeks ago" 같은 표시를 날짜로 어림할 기준.
InnertubePage parseBrowse(Map<String, dynamic> json, DateTime now) {
  final entries = <Map<String, dynamic>>[];
  final seen = <String>{};
  String? next;

  void add(Map<String, dynamic>? e) {
    if (e != null && seen.add(e['id'] as String)) entries.add(e);
  }

  void walk(Object? j) {
    if (j is Map<String, dynamic>) {
      if (j['lockupViewModel'] case final Map<String, dynamic> l) {
        add(_fromLockup(l, now));
        return;
      }
      if (j['videoRenderer'] case final Map<String, dynamic> v) {
        add(_fromVideoRenderer(v, now));
        return;
      }
      if (j['continuationItemRenderer'] case final Map<String, dynamic> c) {
        next ??= _token(c);
        return;
      }
      for (final e in j.entries) {
        if (!_skipKeys.contains(e.key)) walk(e.value);
      }
    } else if (j is List) {
      for (final v in j) {
        walk(v);
      }
    }
  }

  walk(json);
  return InnertubePage(entries, next);
}

String? _token(Object? j) {
  if (j is Map<String, dynamic>) {
    if (j['continuationCommand'] case {'token': final String t}) return t;
    for (final v in j.values) {
      final t = _token(v);
      if (t != null) return t;
    }
  } else if (j is List) {
    for (final v in j) {
      final t = _token(v);
      if (t != null) return t;
    }
  }
  return null;
}

/// 새 형식(lockupViewModel): 채널 영상·재생목록 탭, 재생목록 안 영상
Map<String, dynamic>? _fromLockup(Map<String, dynamic> l, DateTime now) {
  final id = l['contentId'];
  final type = l['contentType'];
  final meta = l['metadata']?['lockupMetadataViewModel'];
  final title = meta?['title']?['content'];
  if (id is! String || title is! String) return null;
  if (type == 'LOCKUP_CONTENT_TYPE_PLAYLIST') return {'id': id, 'title': title};
  if (type != 'LOCKUP_CONTENT_TYPE_VIDEO') return null;

  int? views;
  DateTime? uploaded;
  final rows = meta?['metadata']?['contentMetadataViewModel']?['metadataRows'];
  for (final row in rows is List ? rows : const []) {
    final parts = row is Map ? row['metadataParts'] : null;
    for (final p in parts is List ? parts : const []) {
      final t = p is Map ? (p['text']?['content']) : null;
      if (t is! String) continue;
      views ??= parseViewCount(t);
      uploaded ??= parseAgo(t, now);
    }
  }
  return {
    'id': id,
    'title': title,
    'duration': ?parseClock(_badge(l['contentImage']) ?? ''),
    'view_count': ?views,
    if (uploaded != null) 'timestamp': uploaded.millisecondsSinceEpoch ~/ 1000,
  };
}

/// 썸네일 위 길이 표시 ("8:35")
String? _badge(Object? j) {
  if (j is Map<String, dynamic>) {
    if (j['thumbnailBadgeViewModel'] case {'text': final String t}) {
      if (parseClock(t) != null) return t;
    }
    for (final v in j.values) {
      final t = _badge(v);
      if (t != null) return t;
    }
  } else if (j is List) {
    for (final v in j) {
      final t = _badge(v);
      if (t != null) return t;
    }
  }
  return null;
}

/// 예전 형식(videoRenderer): 채널 안 검색 결과
Map<String, dynamic>? _fromVideoRenderer(Map<String, dynamic> v, DateTime now) {
  final id = v['videoId'];
  final title = _text(v['title']);
  if (id is! String || title == null) return null;
  final uploaded = parseAgo(_text(v['publishedTimeText']) ?? '', now);
  return {
    'id': id,
    'title': title,
    'duration': ?parseClock(_text(v['lengthText']) ?? ''),
    'view_count': ?parseViewCount(_text(v['viewCountText']) ?? ''),
    if (uploaded != null) 'timestamp': uploaded.millisecondsSinceEpoch ~/ 1000,
  };
}

/// {simpleText} 또는 {runs: [{text}]}
String? _text(Object? j) {
  if (j is! Map) return null;
  if (j['simpleText'] case final String s) return s;
  if (j['runs'] case final List runs) {
    return runs.map((r) => r is Map ? r['text'] ?? '' : '').join();
  }
  return null;
}

/// "8:35" / "1:02:03" → 초. 형식이 다르면 null.
int? parseClock(String s) {
  final m = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{2})$').firstMatch(s.trim());
  if (m == null) return null;
  return (int.tryParse(m[1] ?? '0') ?? 0) * 3600 +
      int.parse(m[2]!) * 60 +
      int.parse(m[3]!);
}

/// "29K views" / "1.2M views" / "30,553,705 views" / "No views" → 회수. 조회수 표시가 아니면 null.
int? parseViewCount(String s) {
  final t = s.trim();
  if (RegExp(r'^No views$', caseSensitive: false).hasMatch(t)) return 0;
  final m = RegExp(
    r'^([\d,.]+)\s*([KMB])?\s+views?$',
    caseSensitive: false,
  ).firstMatch(t);
  if (m == null) return null;
  final n = double.tryParse(m[1]!.replaceAll(',', ''));
  if (n == null) return null;
  final mul = switch (m[2]?.toUpperCase()) {
    'K' => 1e3,
    'M' => 1e6,
    'B' => 1e9,
    _ => 1.0,
  };
  return (n * mul).round();
}

/// "13 hours ago" / "3 weeks ago" / "Streamed 2 years ago" → 어림한 날짜 (yt-dlp approximate_date와 같은 방식).
/// 형식이 다르면 null.
DateTime? parseAgo(String s, DateTime now) {
  final m = RegExp(
    r'(\d+)\s+(second|minute|hour|day|week|month|year)s?\s+ago$',
  ).firstMatch(s.trim());
  if (m == null) return null;
  final n = int.parse(m[1]!);
  final d = switch (m[2]) {
    'second' => Duration(seconds: n),
    'minute' => Duration(minutes: n),
    'hour' => Duration(hours: n),
    'day' => Duration(days: n),
    'week' => Duration(days: 7 * n),
    'month' => Duration(days: 30 * n),
    _ => Duration(days: 365 * n),
  };
  return now.subtract(d);
}

/// 목록 주소 → browse 요청 본문. 채널 핸들(@TED)은 [channelId]로 채널 ID를 찾는다.
/// 지원하지 않는 주소면 null.
Future<Map<String, dynamic>?> browseRequestFor(
  String url,
  Future<String> Function(String handle) channelId,
) async {
  final u = Uri.parse(url);
  if (u.path == '/playlist') {
    final list = u.queryParameters['list'];
    return list == null ? null : {'browseId': 'VL$list'};
  }
  final m = RegExp(r'^/@([^/]+)/(videos|playlists|search)$').firstMatch(u.path);
  if (m == null) return null;
  final id = await channelId(m[1]!);
  return switch (m[2]) {
    // yt-dlp가 쓰는 탭 값 (채널 페이지의 동영상 / 재생목록 / 검색 탭)
    'videos' => {'browseId': id, 'params': 'EgZ2aWRlb3PyBgQKAjoA'},
    'playlists' => {'browseId': id, 'params': 'EglwbGF5bGlzdHPyBgQKAkIA'},
    _ => {
      'browseId': id,
      'params': 'EgZzZWFyY2jyBgQKAloA',
      'query': u.queryParameters['query'] ?? '',
    },
  };
}

/// InnerTube 목록 받기. 주소마다 받은 항목과 다음 페이지 토큰을 기억해 두고,
/// yt-dlp처럼 [start]~[end] (1부터, 끝 포함) 범위를 돌려준다.
class InnertubeBrowser {
  InnertubeBrowser({
    required this.channelId,
    Future<Map<String, dynamic>> Function(Map<String, dynamic> body)? post,
    DateTime Function()? now,
  }) : _post = post ?? _postBrowse,
       _now = now ?? DateTime.now;

  /// 채널 핸들 → 채널 ID (UC…)
  final Future<String> Function(String handle) channelId;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body) _post;
  final DateTime Function() _now;

  final _lists = <String, _Paged>{};

  Future<Map<String, dynamic>> listPlaylist(
    String url, {
    required int start,
    required int end,
  }) async {
    // 처음부터 다시 받으면 (새로 고침) 기억해 둔 것을 버린다
    if (start <= 1) _lists.remove(url);
    var p = _lists[url];
    if (p == null) {
      final req = await browseRequestFor(url, channelId);
      if (req == null) throw ArgumentError('지원하지 않는 YouTube 목록 주소: $url');
      final page = parseBrowse(await _post(req), _now());
      p = _lists[url] = _Paged(page.entries, page.continuation);
    }
    while (p.entries.length < end && p.next != null) {
      final page = parseBrowse(await _post({'continuation': p.next}), _now());
      final ids = {for (final e in p.entries) e['id']};
      p.entries.addAll(page.entries.where((e) => ids.add(e['id'])));
      // 새 항목 없이 토큰만 오면 끝없이 돌지 않게 멈춘다
      p.next = page.entries.isEmpty ? null : page.continuation;
    }
    final from = (start - 1).clamp(0, p.entries.length);
    final to = end.clamp(from, p.entries.length);
    return {'entries': p.entries.sublist(from, to)};
  }
}

class _Paged {
  _Paged(this.entries, this.next);
  final List<Map<String, dynamic>> entries;
  String? next;
}

/// YouTube 웹 클라이언트로 browse 요청 (yt-dlp와 같은 방식, 로그인 없음)
Future<Map<String, dynamic>> _postBrowse(Map<String, dynamic> body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('https://www.youtube.com/youtubei/v1/browse?prettyPrint=false'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': '2.20251110.00.00',
            'hl': 'en',
            'gl': 'US',
          },
        },
        ...body,
      }),
    );
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw HttpException('YouTube 목록 요청 실패 (${res.statusCode})');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}
