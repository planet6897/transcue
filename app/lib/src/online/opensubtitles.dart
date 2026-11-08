import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// OpenSubtitles 파일 해시: 파일 크기 + 앞/뒤 64KB를 8바이트(LE) 단위로 더한 값 (mod 2^64).
/// 같은 릴리스 파일이면 같은 해시 → 싱크가 맞는 자막을 찾을 수 있다.
Future<String> openSubtitlesHash(File file) async {
  const chunk = 65536;
  final size = await file.length();
  if (size < chunk * 2) throw const FormatException('파일이 너무 작습니다');
  final raf = await file.open();
  try {
    var h = size; // Dart int는 64비트로 감싸며 더해진다 (mod 2^64)
    for (final offset in [0, size - chunk]) {
      await raf.setPosition(offset);
      final data = ByteData.sublistView(await raf.read(chunk));
      for (var i = 0; i < chunk; i += 8) {
        h += data.getUint64(i, Endian.little);
      }
    }
    return BigInt.from(h).toUnsigned(64).toRadixString(16).padLeft(16, '0');
  } finally {
    await raf.close();
  }
}

/// 파일 이름에서 찾은 검색 정보
class ReleaseName {
  const ReleaseName({
    required this.title,
    this.year,
    this.season,
    this.episode,
  });
  final String title;
  final int? year;
  final int? season;
  final int? episode;

  bool get isEpisode => season != null && episode != null;
}

final _episodeRe = RegExp(
  r'^(.*?)[\s._\-\[(]*[sS](\d{1,2})[\s._]*[eE](\d{1,3})',
);
final _yearRe = RegExp(r'^(.*?)[\s._\-\[(]+((?:19|20)\d{2})(?:[\s._\-\])]|$)');

String _cleanTitle(String s) => s
    .replaceAll(RegExp(r'[._]'), ' ')
    .replaceAll(RegExp(r'\s*\((?:19|20)\d{2}\)\s*'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// `Knight Rider S01E01-E02 Knight of the Phoenix.mkv` → Knight Rider, S1E1
/// `The.Matrix.1999.1080p.BluRay.mkv` → The Matrix (1999)
ReleaseName parseReleaseName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  var name = parts.last;
  name = name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');
  final ep = _episodeRe.firstMatch(name);
  if (ep != null && _cleanTitle(ep[1]!).isNotEmpty) {
    // 드라마 연도: 파일 이름(Show.2008.S01E01) 또는 폴더 이름(Show (1982)/Season 1)
    // 같은 제목의 리메이크(Knight Rider 1982 ↔ 2008)를 가르는 데 쓴다
    int? year = _yearOf(ep[1]!);
    for (final dir in parts.reversed.skip(1).take(3)) {
      year ??= _yearOf(dir);
    }
    return ReleaseName(
      title: _cleanTitle(ep[1]!),
      year: year,
      season: int.parse(ep[2]!),
      episode: int.parse(ep[3]!),
    );
  }
  final y = _yearRe.firstMatch(name);
  if (y != null && _cleanTitle(y[1]!).isNotEmpty) {
    return ReleaseName(title: _cleanTitle(y[1]!), year: int.parse(y[2]!));
  }
  return ReleaseName(title: _cleanTitle(name));
}

final _anyYearRe = RegExp(
  r'(?:^|[\s._\-\[(])((?:19|20)\d{2})(?=[\s._\-\])]|$)',
);

int? _yearOf(String s) {
  final m = _anyYearRe.firstMatch(s);
  return m == null ? null : int.parse(m[1]!);
}

/// 검색 결과 하나 (자막 파일 하나)
class SubtitleHit {
  const SubtitleHit({
    required this.fileId,
    required this.language,
    required this.hashMatch,
    required this.downloads,
    required this.machine,
    required this.release,
    this.title = '',
    this.parentTitle = '',
    this.season,
    this.episode,
    this.year,
  });

  /// 작품(에피소드) 연도 (feature_details.year)
  final int? year;

  /// 자막이 속한 작품 정보 (feature_details) — 이름 검색 결과 검증용
  final String title;
  final String parentTitle;
  final int? season;
  final int? episode;

  final int fileId;
  final String language;
  final bool hashMatch;
  final int downloads;

  /// 기계/AI 번역 자막 여부 (가능하면 사람이 만든 자막 선택)
  final bool machine;
  final String release;

  static List<SubtitleHit> fromSearchJson(Map<String, dynamic> j) {
    final out = <SubtitleHit>[];
    for (final d in (j['data'] as List? ?? []).cast<Map>()) {
      final a = (d['attributes'] as Map?) ?? {};
      final files = (a['files'] as List? ?? []).cast<Map>();
      // 여러 파일(CD1/CD2)로 나뉜 자막은 제외
      if (files.length != 1 || files.first['file_id'] == null) continue;
      final f = (a['feature_details'] as Map?) ?? {};
      out.add(
        SubtitleHit(
          fileId: (files.first['file_id'] as num).toInt(),
          language: '${a['language'] ?? ''}',
          hashMatch: a['moviehash_match'] == true,
          downloads: (a['download_count'] as num?)?.toInt() ?? 0,
          machine:
              a['machine_translated'] == true || a['ai_translated'] == true,
          release: '${a['release'] ?? ''}',
          title: '${f['title'] ?? f['movie_name'] ?? ''}',
          parentTitle: '${f['parent_title'] ?? ''}',
          season: (f['season_number'] as num?)?.toInt(),
          episode: (f['episode_number'] as num?)?.toInt(),
          year: (f['year'] as num?)?.toInt() ?? int.tryParse('${f['year']}'),
        ),
      );
    }
    return out;
  }
}

const _stop = {'the', 'a', 'an', 'and', 'of', 'for', 'to', 'in', 'on', '&'};

Set<String> _tokens(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .split(RegExp(r'[^a-z0-9가-힣ぁ-んァ-ン一-龥]+'))
    .where((t) => t.isNotEmpty && !_stop.contains(t))
    .toSet();

/// 제목 유사도 (단어 집합 Jaccard, 0~1)
double titleSimilarity(String a, String b) {
  final x = _tokens(a), y = _tokens(b);
  if (x.isEmpty || y.isEmpty) return 0;
  return x.intersection(y).length / x.union(y).length;
}

/// 이름 검색 결과가 이 파일의 작품이 맞는지.
/// 파일 해시가 일치하면 믿고, 아니면 제목(드라마는 시즌/에피소드까지)이 맞아야 한다.
/// (실사례: '2 Girls Going 4 Broke' → 'Chief Daddy 2: Going for Broke'가 잡혀 엉뚱한 자막)
bool matchesRelease(SubtitleHit h, ReleaseName name) {
  if (h.hashMatch) return true;
  final sim = [
    titleSimilarity(name.title, h.title),
    titleSimilarity(name.title, h.parentTitle),
  ].reduce((a, b) => a > b ? a : b);
  if (sim < 0.6) return false;
  if (!_yearFits(h, name)) return false;
  // 릴리스 이름의 시즌이 다르면 제외 (실사례: S01E03 → Knight.Rider.S04.DVDRip)
  if (name.isEpisode) {
    final m = RegExp(
      r'(?:^|[\s._\-])[sS](\d{1,2})(?:[eE]\d|[\s._\-]|$)',
    ).firstMatch(h.release);
    if (m != null && int.parse(m[1]!) != name.season) return false;
  }
  if (name.isEpisode && (h.season != null || h.episode != null)) {
    return h.season == name.season && h.episode == name.episode;
  }
  return true;
}

/// 연도 검사: 같은 제목의 다른 작품(리메이크) 걸러내기.
/// (실사례: Knight Rider (1982) S01E03 → Knight.Rider.2008.S01E03 자막)
bool _yearFits(SubtitleHit h, ReleaseName name) {
  final want = name.year;
  if (want == null) return true;
  // 릴리스 이름에 박힌 연도(Show.2008.S01E03)는 작품 연도 → 거의 같아야 한다
  final rel = _yearOf(h.release);
  if (rel != null && (rel - want).abs() > 1) return false;
  final y = h.year;
  if (y == null) return true;
  if (!name.isEpisode) return (y - want).abs() <= 1;
  // 드라마: 에피소드 방영 연도는 시즌이 지날수록 늦어진다 (첫 방영 연도 ~ +시즌 수)
  return y >= want - 1 && y <= want + name.season! + 1;
}

/// 해당 언어에서 가장 좋은 자막: 해시 일치 > 사람 번역 > 다운로드 수
/// [name]을 주면 제목이 맞지 않는 결과는 뺀다.
SubtitleHit? pickBest(
  List<SubtitleHit> hits,
  String lang, {
  ReleaseName? name,
}) {
  final c =
      hits
          .where((h) => h.language.toLowerCase() == lang)
          .where((h) => name == null || matchesRelease(h, name))
          .toList()
        ..sort((a, b) {
          if (a.hashMatch != b.hashMatch) return a.hashMatch ? -1 : 1;
          if (a.machine != b.machine) return a.machine ? 1 : -1;
          return b.downloads.compareTo(a.downloads);
        });
  return c.firstOrNull;
}

/// ISO 639-2(ffprobe) → OpenSubtitles 언어 코드
String osLang(String? iso) => switch (iso) {
  'eng' || 'en' || null => 'en',
  'jpn' || 'ja' => 'ja',
  'fra' || 'fre' || 'fr' => 'fr',
  'deu' || 'ger' || 'de' => 'de',
  'spa' || 'es' => 'es',
  'ita' || 'it' => 'it',
  'rus' || 'ru' => 'ru',
  'chi' || 'zho' || 'zh' => 'zh-cn',
  'kor' || 'ko' => 'ko',
  'por' || 'pt' => 'pt-pt',
  _ => iso.length == 2 ? iso : 'en',
};

class OpenSubtitlesException implements Exception {
  const OpenSubtitlesException(this.message);
  final String message;
  @override
  String toString() => 'OpenSubtitles: $message';
}

/// OpenSubtitles.com REST API v1 클라이언트.
/// API 키는 필수, 아이디/비밀번호는 선택 (넣으면 계정의 다운로드 한도 사용).
class OpenSubtitlesClient {
  OpenSubtitlesClient({
    required this.apiKey,
    this.username = '',
    this.password = '',
  });

  final String apiKey;
  final String username;
  final String password;

  static const userAgent = 'Transcue v0.1.0';
  String _host = 'api.opensubtitles.com';
  String? _token;

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    // API 규칙: 쿼리 파라미터는 이름순, 값은 소문자 (아니면 리다이렉트됨)
    final q = query == null
        ? null
        : Map.fromEntries(
            (query.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
                .map((e) => MapEntry(e.key, e.value.toLowerCase())),
          );
    final uri = Uri.https(_host, '/api/v1$path', q);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.openUrl(method, uri);
      req.headers
        ..set('Api-Key', apiKey)
        ..set('User-Agent', userAgent)
        ..set('Accept', 'application/json');
      if (_token != null) req.headers.set('Authorization', 'Bearer $_token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw OpenSubtitlesException(
          'API 키 또는 계정 정보가 올바르지 않습니다 (${res.statusCode})',
        );
      }
      if (res.statusCode == 406) {
        throw const OpenSubtitlesException('오늘 다운로드 한도를 모두 사용했습니다');
      }
      if (res.statusCode == 429) {
        throw const OpenSubtitlesException('요청이 너무 많습니다. 잠시 후 다시 시도하세요');
      }
      if (res.statusCode >= 300) {
        throw OpenSubtitlesException(
          'HTTP ${res.statusCode}: ${text.length > 200 ? text.substring(0, 200) : text}',
        );
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> _login() async {
    if (_token != null || username.isEmpty || password.isEmpty) return;
    final j = await _call(
      'POST',
      '/login',
      body: {'username': username, 'password': password},
    );
    _token = j['token'] as String?;
    final base = j['base_url'] as String?;
    if (base != null && base.isNotEmpty) {
      _host = base.replaceFirst(RegExp(r'^https?://'), '');
    }
  }

  /// 해시 + 이름으로 검색. [languages]는 'en,ko' 형식.
  Future<List<SubtitleHit>> search({
    String? hash,
    required ReleaseName name,
    required String languages,
  }) async {
    final hits = <SubtitleHit>[];
    if (hash != null) {
      hits.addAll(
        SubtitleHit.fromSearchJson(
          await _call(
            'GET',
            '/subtitles',
            query: {'moviehash': hash, 'languages': languages},
          ),
        ),
      );
    }
    // 해시로 원하는 언어를 다 못 찾았으면 이름 검색 결과를 더한다
    final langs = languages.split(',');
    if (langs.any((l) => !hits.any((h) => h.language == l && h.hashMatch))) {
      hits.addAll(
        SubtitleHit.fromSearchJson(
          await _call(
            'GET',
            '/subtitles',
            query: {
              'query': name.title,
              'languages': languages,
              if (name.isEpisode) ...{
                'type': 'episode',
                'season_number': '${name.season}',
                'episode_number': '${name.episode}',
              } else if (name.year != null)
                'year': '${name.year}',
            },
          ),
        ),
      );
    }
    return hits;
  }

  /// 자막 파일 내용(SRT)을 받는다. 다운로드 한도 1개 사용.
  Future<String> download(int fileId) async {
    await _login();
    final j = await _call('POST', '/download', body: {'file_id': fileId});
    final link = j['link'] as String?;
    if (link == null) throw const OpenSubtitlesException('다운로드 링크를 받지 못했습니다');
    debugPrint('OpenSubtitles download remaining: ${j['remaining']}');
    final client = HttpClient();
    try {
      final res = await (await client.getUrl(Uri.parse(link))).close();
      final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return latin1.decode(bytes); // 오래된 자막은 UTF-8이 아닐 수 있다
      }
    } finally {
      client.close();
    }
  }
}
