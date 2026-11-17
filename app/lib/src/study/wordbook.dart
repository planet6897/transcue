import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../subtitle/bilingual_cue.dart';

/// 단어장에 모아 둔 단어 하나, 또는 문장 하나.
/// 나중에 그 장면으로 돌아가 다시 들을 수 있도록 영상과 시간을 함께 기억한다.
class StudyItem {
  const StudyItem({
    this.word,
    this.surface,
    this.pos,
    this.meaning,
    required this.sentence,
    this.translation,
    required this.source,
    required this.title,
    required this.start,
    required this.end,
    required this.savedAt,
    this.note,
  });

  /// 단어 [w]를 [cue] 문장과 함께
  factory StudyItem.ofWord(
    VocabItem w,
    BilingualCue cue, {
    required String source,
    required String title,
  }) => StudyItem(
    word: w.lemma,
    surface: w.text,
    pos: w.pos,
    meaning: w.meaning,
    sentence: cue.original,
    translation: cue.translation,
    source: source,
    title: title,
    start: cue.start,
    end: cue.end,
    savedAt: DateTime.now(),
  );

  /// 문장 [cue] 하나
  factory StudyItem.ofSentence(
    BilingualCue cue, {
    required String source,
    required String title,
    String? note,
  }) => StudyItem(
    note: note,
    sentence: cue.original,
    translation: cue.translation,
    source: source,
    title: title,
    start: cue.start,
    end: cue.end,
    savedAt: DateTime.now(),
  );

  /// 사전형 단어. null이면 문장을 저장한 것
  final String? word;

  /// 자막에 나온 그대로 (문장에서 강조할 부분)
  final String? surface;
  final String? pos;
  final String? meaning;
  final String sentence;
  final String? translation;

  /// 영상 파일 경로 또는 YouTube 주소
  final String source;
  final String title;
  final Duration start;
  final Duration end;
  final DateTime savedAt;

  /// 문장 해설 (AI) — 해설을 보고 저장했을 때
  final String? note;

  bool get isWord => word != null;

  /// 같은 것인지 가리는 열쇠. 단어는 영상이 달라도 한 번만 모은다.
  String get key => keyOfWord(word) ?? keyOfSentence(source, start);

  static String? keyOfWord(String? lemma) =>
      lemma == null ? null : 'w:${lemma.trim().toLowerCase()}';

  static String keyOfSentence(String source, Duration start) =>
      's:$source@${start.inMilliseconds}';

  Map<String, Object?> toJson() => {
    if (word != null) 'w': word,
    if (surface != null) 'x': surface,
    if (pos != null) 'p': pos,
    if (meaning != null) 'm': meaning,
    'o': sentence,
    if (translation != null) 't': translation,
    'src': source,
    'title': title,
    's': start.inMilliseconds,
    'e': end.inMilliseconds,
    'at': savedAt.millisecondsSinceEpoch,
    if (note != null) 'n': note,
  };

  factory StudyItem.fromJson(Map<String, dynamic> j) => StudyItem(
    word: j['w'] as String?,
    surface: j['x'] as String?,
    pos: j['p'] as String?,
    meaning: j['m'] as String?,
    sentence: j['o'] as String,
    translation: j['t'] as String?,
    source: j['src'] as String,
    title: j['title'] as String? ?? '',
    start: Duration(milliseconds: (j['s'] as num).toInt()),
    end: Duration(milliseconds: (j['e'] as num).toInt()),
    savedAt: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
    note: j['n'] as String?,
  );
}

/// 단어장 (wordbook.json). 최근에 모은 것이 앞에 온다.
class Wordbook extends ChangeNotifier {
  Wordbook(this._file);

  /// 저장 파일 (앱 데이터 폴더를 알아내는 데 시간이 걸려 Future로 받는다)
  final Future<File> _file;
  final List<StudyItem> _items = [];
  final Set<String> _keys = {};
  Future<void>? _loading;

  List<StudyItem> get items => List.unmodifiable(_items);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final file = await _file;
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString()) as List<dynamic>;
      for (final e in j) {
        final it = StudyItem.fromJson(e as Map<String, dynamic>);
        if (_keys.add(it.key)) _items.add(it);
      }
    } catch (e) {
      debugPrint('[wordbook] load failed: $e');
    } finally {
      notifyListeners();
    }
  }

  Future<void> _save() async {
    try {
      final file = await _file;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode([for (final it in _items) it.toJson()]),
      );
    } catch (e) {
      debugPrint('[wordbook] save failed: $e');
    }
  }

  bool hasWord(String lemma) => _keys.contains(StudyItem.keyOfWord(lemma));

  bool hasSentence(String source, Duration start) =>
      _keys.contains(StudyItem.keyOfSentence(source, start));

  /// 넣는다. 이미 있으면 새 내용으로 바꾼다 (예: 해설을 붙여 다시 저장).
  Future<void> put(StudyItem item) async {
    await load();
    final i = _items.indexWhere((e) => e.key == item.key);
    if (i >= 0) {
      _items[i] = item;
    } else {
      _keys.add(item.key);
      _items.insert(0, item);
    }
    notifyListeners();
    await _save();
  }

  /// 없으면 넣고 있으면 뺀다. 넣었으면 true.
  Future<bool> toggle(StudyItem item) async {
    await load();
    final added = _keys.add(item.key);
    if (added) {
      _items.insert(0, item);
    } else {
      _keys.remove(item.key);
      _items.removeWhere((e) => e.key == item.key);
    }
    notifyListeners();
    await _save();
    return added;
  }

  Future<void> remove(StudyItem item) async {
    await load();
    if (!_keys.remove(item.key)) return;
    _items.removeWhere((e) => e.key == item.key);
    notifyListeners();
    await _save();
  }
}

/// 단어장을 CSV로 (엑셀·Anki에서 불러오기용, UTF-8 BOM 포함)
String wordbookCsv(List<StudyItem> items) {
  String cell(String? s) {
    final v = (s ?? '').replaceAll(RegExp(r'[\r\n]+'), ' ');
    return RegExp(r'[",]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
  }

  String time(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  final b = StringBuffer('\uFEFF단어,품사,뜻,문장,번역,영상,시간,해설\r\n');
  for (final it in items) {
    b.write(
      [
        cell(it.word),
        cell(it.pos),
        cell(it.meaning),
        cell(it.sentence),
        cell(it.translation),
        cell(it.title),
        time(it.start),
        cell(it.note),
      ].join(','),
    );
    b.write('\r\n');
  }
  return b.toString();
}
