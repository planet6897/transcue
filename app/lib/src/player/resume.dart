import 'dart:convert';
import 'dart:io';

/// 이어 보기: 영상별 마지막 재생 위치를 기억한다 (positions.json).
class PlaybackPositions {
  PlaybackPositions(this._file);

  final File _file;
  final Map<String, ({int ms, int at})> _map = {};
  bool _loaded = false;

  /// 기억하는 영상 수 (오래된 것부터 지운다)
  static const maxEntries = 300;

  /// 이보다 앞이면 기억하지 않는다 (처음부터 보면 됨)
  static const minResume = Duration(seconds: 10);

  /// 끝에서 이만큼 안쪽이면 다 본 것으로 보고 지운다 (엔딩 크레딧)
  static const endMargin = Duration(seconds: 60);

  static String keyForPath(String path) => 'file:$path';
  static String keyForYoutube(String id) => 'yt:$id';

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      for (final e in j.entries) {
        final v = (e.value as List).cast<num>();
        _map[e.key] = (ms: v[0].toInt(), at: v[1].toInt());
      }
    } catch (_) {}
  }

  /// 이어 볼 위치 (없으면 null)
  Future<Duration?> get(String key) async {
    await _load();
    final v = _map[key];
    return v == null ? null : Duration(milliseconds: v.ms);
  }

  /// 위치 기록. 너무 앞이거나 거의 끝까지 봤으면 지운다.
  /// 바뀐 게 있으면 true.
  Future<bool> put(String key, Duration pos, Duration duration) async {
    await _load();
    final done =
        pos < minResume ||
        (duration > Duration.zero && pos > duration - endMargin);
    if (done) return _map.remove(key) != null;
    final old = _map[key];
    if (old != null && (old.ms - pos.inMilliseconds).abs() < 1000) {
      return false;
    }
    _map[key] = (
      ms: pos.inMilliseconds,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    if (_map.length > maxEntries) {
      final oldest = _map.entries.reduce(
        (a, b) => a.value.at < b.value.at ? a : b,
      );
      _map.remove(oldest.key);
    }
    return true;
  }

  Future<void> save() async {
    if (!_loaded) return;
    try {
      await _file.writeAsString(
        jsonEncode({
          for (final e in _map.entries) e.key: [e.value.ms, e.value.at],
        }),
      );
    } catch (_) {}
  }
}

/// 01:02:03 / 12:34
String formatPosition(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}
