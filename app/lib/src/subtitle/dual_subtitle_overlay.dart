import 'dart:async';

import 'package:flutter/material.dart';

import '../settings/app_settings.dart' show PracticeMode;
import 'bilingual_cue.dart';
import 'ruby_text.dart';

/// 자막 표시 상태 (현재 자막 목록 + 원문/번역 표시 여부).
/// 전체 화면은 별도 화면(route)이라 부모 setState가 닿지 않으므로,
/// 오버레이가 이 객체와 재생 위치를 직접 구독한다.
class DualSubtitleState extends ChangeNotifier {
  List<BilingualCue> _cues = const [];
  bool _showOriginal = true;
  bool _showTranslation = true;
  bool _showVocab = false;

  bool get showVocab => _showVocab;
  set showVocab(bool v) {
    _showVocab = v;
    notifyListeners();
  }

  /// 일본어 읽는 법 표시
  bool get showRuby => _showRuby;
  bool _showRuby = false;
  set showRuby(bool v) {
    _showRuby = v;
    notifyListeners();
  }

  /// 듣기 연습 (자막 가리기). 바꾸면 열어 본 줄도 다시 가린다.
  PracticeMode get practice => _practice;
  PracticeMode _practice = PracticeMode.off;
  set practice(PracticeMode v) {
    _practice = v;
    _revealed.clear();
    notifyListeners();
  }

  /// 듣기 연습에서 열어 본 줄 (시작 시각 ms)
  final _revealed = <int>{};

  bool _isRevealed(BilingualCue c) =>
      _revealed.contains(c.start.inMilliseconds);

  bool hidesOriginal(BilingualCue c) =>
      _practice == PracticeMode.hideAll && !_isRevealed(c);

  bool hidesTranslation(BilingualCue c) =>
      _practice != PracticeMode.off && !_isRevealed(c);

  /// 가린 데가 있는 줄인지
  bool hides(BilingualCue c) => hidesOriginal(c) || hidesTranslation(c);

  /// 가린 줄을 연다
  void reveal(BilingualCue c) {
    if (_revealed.add(c.start.inMilliseconds)) notifyListeners();
  }

  List<BilingualCue> get cues => _cues;
  bool get showOriginal => _showOriginal;
  bool get showTranslation => _showTranslation;

  set cues(List<BilingualCue> v) {
    if (identical(v, _cues)) return;
    _cues = v;
    notifyListeners();
  }

  set showOriginal(bool v) {
    _showOriginal = v;
    notifyListeners();
  }

  set showTranslation(bool v) {
    _showTranslation = v;
    notifyListeners();
  }

  bool _copied = false;
  Timer? _copiedTimer;

  /// 방금 자막을 복사했는지 (자막 위에 잠깐 표시)
  bool get copied => _copied;

  void flashCopied() {
    _copied = true;
    notifyListeners();
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1200), () {
      _copied = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  /// [cue]에서 지금 화면에 보이는 줄만 복사용 글로 만든다.
  String copyText(BilingualCue cue) => [
    if (_showOriginal) cue.original,
    if (_showTranslation && cue.translation != null) cue.translation!,
  ].join('\n');
}

/// 재생 위치를 따라 이중 자막을 그린다. 일반 화면/전체 화면 모두에서 동작.
class LiveDualSubtitle extends StatefulWidget {
  const LiveDualSubtitle({
    super.key,
    required this.position,
    required this.currentPosition,
    required this.view,
    this.onTapCue,
    this.saved,
    this.wordSaved,
    this.onTapWord,
  });

  /// 단어장 (바뀌면 단어 옆 별 표시를 다시 그린다)
  final Listenable? saved;
  final bool Function(String lemma)? wordSaved;

  /// 학습 단어를 눌렀을 때 (단어장에 넣기/빼기)
  final void Function(BilingualCue, VocabItem)? onTapWord;

  /// 자막을 눌렀을 때. 자막 상자 밖의 클릭은 아래 조작부로 그대로 전달된다.
  final ValueChanged<BilingualCue>? onTapCue;

  /// 재생 위치 스트림 (player.stream.position)
  final Stream<Duration> position;

  /// 현재 재생 위치 (player.state.position) — 화면이 새로 만들어질 때 초기값
  final Duration Function() currentPosition;
  final DualSubtitleState view;

  @override
  State<LiveDualSubtitle> createState() => _LiveDualSubtitleState();
}

/// 재생 위치는 화면이 바뀔 때마다 들어오지만, 보여 줄 줄이 바뀔 때만 다시 그린다
/// (매번 자막 전체를 다시 만들던 것을 줄인다).
class _LiveDualSubtitleState extends State<LiveDualSubtitle> {
  StreamSubscription<Duration>? _sub;
  late Duration _pos = widget.currentPosition();
  BilingualCue? _shown;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(LiveDualSubtitle old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position ||
        old.view != widget.view ||
        old.saved != widget.saved) {
      _unlisten(old);
      _listen();
    }
  }

  @override
  void dispose() {
    _unlisten(widget);
    super.dispose();
  }

  void _listen() {
    _sub = widget.position.listen(_onPosition);
    widget.view.addListener(_onChanged);
    widget.saved?.addListener(_onChanged);
  }

  void _unlisten(LiveDualSubtitle w) {
    _sub?.cancel();
    w.view.removeListener(_onChanged);
    w.saved?.removeListener(_onChanged);
  }

  void _onPosition(Duration p) {
    _pos = p;
    if (!identical(cueAt(widget.view.cues, p), _shown)) setState(() {});
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    // 자막 시간 그대로 표시 (끝난 뒤 더 보여 주면 영상보다 늦게 남아 있는 것처럼 보인다)
    _shown = cueAt(view.cues, _pos);
    return DualSubtitleOverlay(
      cue: _shown,
      showOriginal: view.showOriginal,
      showTranslation: view.showTranslation,
      showVocab: view.showVocab,
      showRuby: view.showRuby,
      hideOriginal: (c) => view.hidesOriginal(c),
      hideTranslation: (c) => view.hidesTranslation(c),
      onTapCue: widget.onTapCue,
      copied: view.copied,
      wordSaved: widget.wordSaved,
      onTapWord: widget.onTapWord,
    );
  }
}

/// 영상 하단에 원문(위) + 한국어 번역(아래)을 겹쳐 보여주는 오버레이.
/// 글자 크기는 영상 영역 높이에 비례 (전체 화면에서 커짐).
class DualSubtitleOverlay extends StatelessWidget {
  const DualSubtitleOverlay({
    super.key,
    required this.cue,
    this.showOriginal = true,
    this.showTranslation = true,
    this.showVocab = false,
    this.showRuby = false,
    this.hideOriginal,
    this.hideTranslation,
    this.onTapCue,
    this.copied = false,
    this.wordSaved,
    this.onTapWord,
  });

  /// 듣기 연습에서 이 줄의 원문·번역을 가릴지
  final bool Function(BilingualCue)? hideOriginal;
  final bool Function(BilingualCue)? hideTranslation;
  final bool showRuby;

  final ValueChanged<BilingualCue>? onTapCue;
  final bool Function(String lemma)? wordSaved;
  final void Function(BilingualCue, VocabItem)? onTapWord;
  final bool copied;
  final BilingualCue? cue;
  final bool showOriginal;
  final bool showTranslation;
  final bool showVocab;

  static const _vocabColor = Color(0xFF80DEEA);

  @override
  Widget build(BuildContext context) {
    final c = cue;
    if (c == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight.isFinite ? box.maxHeight : 600.0;
        final size = (h * 0.038).clamp(16.0, 48.0);
        final shadow = [Shadow(blurRadius: size * 0.2, color: Colors.black)];
        final hideOrig = hideOriginal?.call(c) ?? false;
        final hideTrans = hideTranslation?.call(c) ?? false;
        // 원문을 가렸으면 학습 단어도 답이 되므로 감춘다
        final words = showVocab && !hideOrig
            ? (c.words ?? const <VocabItem>[])
            : const <VocabItem>[];
        final origStyle = TextStyle(
          fontSize: size,
          color: Colors.white,
          fontWeight: FontWeight.w600,
          shadows: shadow,
        );
        final ruby = showRuby ? c.ruby : null;
        final subtitle = Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            // 하단 재생 컨트롤 막대와 겹치지 않도록 여유를 둔다
            padding: EdgeInsets.fromLTRB(
              24,
              0,
              24,
              (h * 0.09).clamp(48.0, 110.0),
            ),
            child: _tappable(
              c,
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: size * 0.5,
                  vertical: size * 0.3,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showOriginal && hideOrig)
                      HiddenLine(fontSize: size * 0.8)
                    else if (showOriginal && ruby != null)
                      Text.rich(
                        TextSpan(children: rubySpans(ruby, origStyle)),
                        textAlign: TextAlign.center,
                        style: origStyle,
                      )
                    else if (showOriginal)
                      Text.rich(
                        TextSpan(
                          children: [
                            // 학습 단어는 원문에서 색으로 강조
                            for (final (t, hl) in highlightSegments(
                              c.original,
                              [for (final w in words) w.text],
                            ))
                              TextSpan(
                                text: t,
                                style: hl
                                    ? const TextStyle(
                                        color: _vocabColor,
                                        decoration: TextDecoration.underline,
                                        decorationColor: _vocabColor,
                                      )
                                    : null,
                              ),
                          ],
                        ),
                        textAlign: TextAlign.center,
                        style: origStyle,
                      ),
                    if (showTranslation && c.translation != null) ...[
                      SizedBox(height: size * 0.15),
                      if (hideTrans)
                        HiddenLine(
                          fontSize: size * 0.7,
                          // 원문 자리에 이미 안내가 있으면 한 번만
                          hint: !(showOriginal && hideOrig),
                        )
                      else
                        Text(
                          c.translation!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: size * 0.85,
                            color: const Color(0xFFFFE082),
                            shadows: shadow,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
        if (words.isEmpty) return subtitle;
        // 학습 단어: 화면 위쪽에 자막처럼. 누르면 단어장에 넣는다(별 표시)
        final onWord = onTapWord;
        final vocab = IgnorePointer(
          ignoring: onWord == null,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                (h * 0.05).clamp(16.0, 60.0),
                24,
                0,
              ),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: size * 0.5,
                  vertical: size * 0.25,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final w in words)
                      _wordRow(
                        c,
                        w,
                        size,
                        Text.rich(
                          TextSpan(
                            children: [
                              if (onWord != null)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Padding(
                                    padding: EdgeInsets.only(right: size * 0.2),
                                    child: Icon(
                                      (wordSaved?.call(w.lemma) ?? false)
                                          ? Icons.star
                                          : Icons.star_border,
                                      size: size * 0.75,
                                      color: (wordSaved?.call(w.lemma) ?? false)
                                          ? _vocabColor
                                          : Colors.white54,
                                    ),
                                  ),
                                ),
                              TextSpan(
                                text: w.lemma,
                                style: const TextStyle(
                                  color: _vocabColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text: '  ${w.pos}  ',
                                style: const TextStyle(color: Colors.white60),
                              ),
                              TextSpan(text: w.meaning),
                            ],
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: size * 0.72,
                            color: Colors.white,
                            shadows: shadow,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        return Stack(children: [vocab, subtitle]);
      },
    );
  }

  /// 학습 단어 한 줄. [onTapWord]가 있으면 눌러서 단어장에 넣거나 뺀다.
  Widget _wordRow(BilingualCue c, VocabItem w, double size, Widget row) {
    final onWord = onTapWord;
    if (onWord == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onWord(c, w),
        child: row,
      ),
    );
  }

  /// 자막 상자만 클릭을 받는다. [onTapCue]가 없으면 클릭을 통과시킨다.
  Widget _tappable(BilingualCue c, Widget box) {
    final onTap = onTapCue;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 항상 자리를 차지해 표시될 때 자막이 움직이지 않는다
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: copied ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '✓ 복사됨',
                style: TextStyle(
                  color: _vocabColor,
                  fontSize: 13,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
        if (onTap == null)
          IgnorePointer(child: box)
        else
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: () => onTap(c), child: box),
          ),
      ],
    );
  }
}

/// [line]을 강조할 부분과 나머지로 나눈다 (대소문자 무시, 겹치면 앞의 것 우선)
List<(String, bool)> highlightSegments(String line, List<String> targets) {
  final lower = line.toLowerCase();
  final ranges = <(int, int)>[];
  for (final t in targets) {
    final k = t.trim().toLowerCase();
    if (k.isEmpty) continue;
    var from = 0;
    while (true) {
      final i = lower.indexOf(k, from);
      if (i < 0) break;
      final e = i + k.length;
      // 단어 중간이 아닌 곳만 (예: "art"가 "start" 안에서 강조되지 않게)
      bool letter(int j) =>
          j >= 0 && j < line.length && RegExp(r'[A-Za-z]').hasMatch(line[j]);
      if (!letter(i - 1) && !letter(e)) {
        if (!ranges.any((r) => i < r.$2 && e > r.$1)) ranges.add((i, e));
        break;
      }
      from = i + 1;
    }
  }
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(String, bool)>[];
  var p = 0;
  for (final (a, b) in ranges) {
    if (a > p) out.add((line.substring(p, a), false));
    out.add((line.substring(a, b), true));
    p = b;
  }
  if (p < line.length) out.add((line.substring(p), false));
  return out;
}
