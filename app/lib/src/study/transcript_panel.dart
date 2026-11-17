import 'dart:async';

import 'package:flutter/material.dart';

import '../player/resume.dart' show formatPosition;
import '../subtitle/bilingual_cue.dart';
import '../subtitle/dual_subtitle_overlay.dart';
import '../subtitle/ruby_text.dart';
import 'wordbook.dart';

const _accent = Color(0xFF80DEEA);
const _translationColor = Color(0xFFFFE082);

/// 영상 옆에 띄우는 자막 전체 목록 (대본처럼 읽기).
/// 지금 문장을 강조하고 따라 내려가며, 문장을 누르면 그 위치로 간다.
/// 문장(책갈피)과 학습 단어(별)를 단어장에 모을 수 있다.
class TranscriptPanel extends StatefulWidget {
  const TranscriptPanel({
    super.key,
    required this.view,
    required this.book,
    required this.position,
    required this.currentPosition,
    required this.onSeek,
    required this.sentenceSaved,
    required this.onToggleSentence,
    required this.onToggleWord,
    required this.onExplain,
    required this.onClose,
  });

  /// 문장 해설 (AI)
  final ValueChanged<BilingualCue> onExplain;

  final DualSubtitleState view;
  final Wordbook book;
  final Stream<Duration> position;
  final Duration Function() currentPosition;
  final ValueChanged<BilingualCue> onSeek;
  final bool Function(BilingualCue) sentenceSaved;
  final ValueChanged<BilingualCue> onToggleSentence;
  final void Function(BilingualCue, VocabItem) onToggleWord;
  final VoidCallback onClose;

  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

class _TranscriptPanelState extends State<TranscriptPanel> {
  /// 지금 재생 중인 문장 번호 (start <= 재생 위치인 마지막 문장)
  final _current = ValueNotifier<int>(-1);
  final _scroll = ScrollController();
  StreamSubscription<Duration>? _sub;

  /// 줄마다 붙이는 키 (자동으로 따라갈 때 그 줄을 찾는다). 줄 번호가 아니라 시작 시각으로
  /// 붙여, 음성 인식이 줄을 끼워 넣어도 다른 줄들은 그대로 남는다.
  final Map<String, GlobalKey> _keys = {};
  List<String> _ids = const [];

  /// 만들어 둔 줄. 내용이 같으면 같은 위젯을 그대로 돌려줘 다시 그리지 않는다
  /// (줄 하나가 바뀔 때마다 목록 전체를 다시 그리면 긴 영상에서 버벅였다).
  final Map<String, (Object, Widget)> _tiles = {};

  /// 사용자가 목록을 직접 굴린 때. 잠시 동안은 지금 문장으로 따라가지 않는다.
  DateTime _userScrolledAt = DateTime(0);

  @override
  void initState() {
    super.initState();
    _update(widget.currentPosition());
    _sub = widget.position.listen(_update);
    // 처음 열면 지금 문장으로 바로 간다
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow(jump: true));
  }

  @override
  void didUpdateWidget(TranscriptPanel old) {
    super.didUpdateWidget(old);
    // 플레이어를 새로 만들면 재생 위치 스트림도 바뀐다
    if (old.position != widget.position) {
      _sub?.cancel();
      _sub = widget.position.listen(_update);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    _current.dispose();
    super.dispose();
  }

  void _update(Duration pos) {
    final i = lastCueIndexBefore(widget.view.cues, pos);
    if (i == _current.value) return;
    _current.value = i;
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  void _follow({bool jump = false}) {
    if (!mounted) return;
    final i = _current.value;
    if (i < 0 || i >= _ids.length) return;
    if (!jump &&
        DateTime.now().difference(_userScrolledAt) <
            const Duration(seconds: 4)) {
      return;
    }
    final ctx = _keys[_ids[i]]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.3,
      duration: jump ? Duration.zero : const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.78),
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.view, widget.book]),
        builder: (context, _) {
          final cues = widget.view.cues;
          final ids = _idsOf(cues);
          if (ids.length != _ids.length) {
            // 음성 인식이 줄을 끼워 넣으면 지금 문장 번호가 달라진다
            // (그리는 중에는 다른 줄을 다시 그리게 할 수 없어 다음 프레임에)
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _current.value = -2; // 같은 번호여도 새 줄들에 다시 알린다
              _update(widget.currentPosition());
            });
          }
          _ids = ids;
          if (_keys.length > ids.length * 2 + 50) _prune(ids);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(cues.length),
              const Divider(height: 1, color: Colors.white24),
              Expanded(
                child: cues.isEmpty
                    ? const Center(
                        child: Text(
                          '아직 자막이 없습니다',
                          style: TextStyle(color: Colors.white60),
                        ),
                      )
                    : NotificationListener<UserScrollNotification>(
                        onNotification: (_) {
                          _userScrolledAt = DateTime.now();
                          return false;
                        },
                        child: SingleChildScrollView(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < cues.length; i++)
                                _tile(i, cues[i], ids[i]),
                            ],
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 줄마다 고유한 이름: 시작 시각 (같은 시각이 겹치면 순번을 붙인다)
  static List<String> _idsOf(List<BilingualCue> cues) {
    final ids = List<String>.filled(cues.length, '');
    var dup = 0;
    for (var i = 0; i < cues.length; i++) {
      final ms = cues[i].start.inMilliseconds;
      dup = i > 0 && cues[i - 1].start.inMilliseconds == ms ? dup + 1 : 0;
      ids[i] = dup == 0 ? '$ms' : '$ms#$dup';
    }
    return ids;
  }

  void _prune(List<String> ids) {
    final live = ids.toSet();
    _keys.removeWhere((id, _) => !live.contains(id));
    _tiles.removeWhere((id, _) => !live.contains(id));
  }

  Widget _tile(int i, BilingualCue cue, String id) {
    final v = widget.view;
    final hideO = v.hidesOriginal(cue);
    final hideT = v.hidesTranslation(cue);
    final saved = widget.sentenceSaved(cue);
    final words = cue.words;
    // 이 줄의 모양을 정하는 값들. 모두 같으면 만들어 둔 위젯을 그대로 쓴다.
    final sig = (
      cue,
      i,
      v.showOriginal,
      v.showTranslation,
      v.showVocab,
      v.showRuby,
      hideO,
      hideT,
      saved,
      v.showVocab && words != null
          ? [for (final w in words) widget.book.hasWord(w.lemma) ? 1 : 0].join()
          : '',
    );
    final cached = _tiles[id];
    if (cached != null && cached.$1 == sig) return cached.$2;
    final tile = _CueTile(
      key: _keys.putIfAbsent(id, GlobalKey.new),
      index: i,
      current: _current,
      cue: cue,
      showOriginal: v.showOriginal,
      showTranslation: v.showTranslation,
      showVocab: v.showVocab,
      showRuby: v.showRuby,
      hideOriginal: hideO,
      hideTranslation: hideT,
      onExplain: () => widget.onExplain(cue),
      saved: saved,
      wordSaved: widget.book.hasWord,
      onTap: () => widget.onSeek(cue),
      onToggleSentence: () => widget.onToggleSentence(cue),
      onToggleWord: (w) => widget.onToggleWord(cue, w),
    );
    _tiles[id] = (sig, tile);
    return tile;
  }

  Widget _header(int count) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
    child: Row(
      children: [
        const Icon(Icons.notes, size: 18, color: Colors.white70),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '자막 목록  ·  $count문장',
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
        IconButton(
          tooltip: '지금 문장으로',
          icon: const Icon(Icons.my_location, size: 18),
          color: Colors.white70,
          onPressed: () {
            _userScrolledAt = DateTime(0);
            _follow(jump: true);
          },
        ),
        IconButton(
          tooltip: '닫기 (T)',
          icon: const Icon(Icons.close, size: 18),
          color: Colors.white70,
          onPressed: widget.onClose,
        ),
      ],
    ),
  );
}

/// 목록의 한 줄. 지금 문장인지 바뀔 때만 다시 그린다.
class _CueTile extends StatefulWidget {
  const _CueTile({
    super.key,
    required this.index,
    required this.current,
    required this.cue,
    required this.showOriginal,
    required this.showTranslation,
    required this.showVocab,
    required this.showRuby,
    required this.hideOriginal,
    required this.hideTranslation,
    required this.onExplain,
    required this.saved,
    required this.wordSaved,
    required this.onTap,
    required this.onToggleSentence,
    required this.onToggleWord,
  });

  final int index;
  final ValueNotifier<int> current;
  final BilingualCue cue;
  final bool showOriginal;
  final bool showTranslation;
  final bool showVocab;
  final bool showRuby;

  /// 듣기 연습에서 가린 줄 (지나간 줄은 보여 준다)
  final bool hideOriginal;
  final bool hideTranslation;
  final VoidCallback onExplain;
  final bool saved;
  final bool Function(String lemma) wordSaved;
  final VoidCallback onTap;
  final VoidCallback onToggleSentence;
  final ValueChanged<VocabItem> onToggleWord;

  @override
  State<_CueTile> createState() => _CueTileState();
}

class _CueTileState extends State<_CueTile> {
  late bool _active = widget.current.value == widget.index;

  @override
  void initState() {
    super.initState();
    widget.current.addListener(_onCurrent);
  }

  @override
  void didUpdateWidget(_CueTile old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) {
      old.current.removeListener(_onCurrent);
      widget.current.addListener(_onCurrent);
    }
    _active = widget.current.value == widget.index;
  }

  @override
  void dispose() {
    widget.current.removeListener(_onCurrent);
    super.dispose();
  }

  void _onCurrent() {
    final a = widget.current.value == widget.index;
    if (a != _active) setState(() => _active = a);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cue;
    // 아직 듣지 않은 줄(지금 줄 포함)만 가린다
    final ahead = widget.index >= widget.current.value;
    final hideO = widget.hideOriginal && ahead;
    final hideT = widget.hideTranslation && ahead;
    final words = widget.showVocab && !hideO
        ? (c.words ?? const <VocabItem>[])
        : const <VocabItem>[];
    final origStyle = TextStyle(
      color: _active ? Colors.white : Colors.white70,
      fontSize: 15,
      height: 1.3,
    );
    final ruby = widget.showRuby ? c.ruby : null;
    return Container(
      color: _active ? Colors.white.withValues(alpha: 0.12) : null,
      child: InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 46,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    formatPosition(c.start),
                    style: TextStyle(
                      color: _active ? _accent : Colors.white38,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.showOriginal && hideO)
                      const HiddenLine(fontSize: 13, hint: false)
                    else if (widget.showOriginal && ruby != null)
                      Text.rich(
                        TextSpan(children: rubySpans(ruby, origStyle)),
                        style: origStyle,
                      )
                    else if (widget.showOriginal)
                      Text.rich(
                        TextSpan(
                          children: [
                            for (final (t, hl) in highlightSegments(
                              c.original,
                              [for (final w in words) w.text],
                            ))
                              TextSpan(
                                text: t,
                                style: hl
                                    ? const TextStyle(
                                        color: _accent,
                                        decoration: TextDecoration.underline,
                                        decorationColor: _accent,
                                      )
                                    : null,
                              ),
                          ],
                        ),
                        style: origStyle,
                      ),
                    if (widget.showTranslation &&
                        c.translation != null &&
                        hideT)
                      const HiddenLine(fontSize: 12, hint: false)
                    else if (widget.showTranslation && c.translation != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          c.translation!,
                          style: TextStyle(
                            color: _translationColor.withValues(
                              alpha: _active ? 1 : 0.7,
                            ),
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                      ),
                    for (final w in words) _wordRow(w),
                  ],
                ),
              ),
              IconButton(
                tooltip: '문장 해설 (E)',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.lightbulb_outline,
                  size: 20,
                  color: Colors.white38,
                ),
                onPressed: widget.onExplain,
              ),
              IconButton(
                tooltip: widget.saved ? '단어장에서 빼기' : '문장을 단어장에 저장 (S)',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  widget.saved ? Icons.bookmark : Icons.bookmark_border,
                  size: 20,
                  color: widget.saved ? _accent : Colors.white38,
                ),
                onPressed: widget.onToggleSentence,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _wordRow(VocabItem w) {
    final saved = widget.wordSaved(w.lemma);
    return InkWell(
      onTap: () => widget.onToggleWord(w),
      child: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Icon(
              saved ? Icons.star : Icons.star_border,
              size: 16,
              color: saved ? _accent : Colors.white38,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: w.lemma,
                      style: const TextStyle(
                        color: _accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(
                      text: '  ${w.pos}  ',
                      style: const TextStyle(color: Colors.white54),
                    ),
                    TextSpan(text: w.meaning),
                  ],
                ),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
