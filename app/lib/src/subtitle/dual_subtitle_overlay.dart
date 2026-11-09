import 'package:flutter/material.dart';

import 'bilingual_cue.dart';

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

  /// [cue]에서 지금 화면에 보이는 줄만 복사용 글로 만든다.
  String copyText(BilingualCue cue) => [
    if (_showOriginal) cue.original,
    if (_showTranslation && cue.translation != null) cue.translation!,
  ].join('\n');
}

/// 자막이 끝난 뒤 더 보여 주는 시간 (다음 자막이 먼저 시작하면 거기까지)
const lingerAfterCue = Duration(seconds: 1);

/// 재생 위치를 따라 이중 자막을 그린다. 일반 화면/전체 화면 모두에서 동작.
class LiveDualSubtitle extends StatelessWidget {
  const LiveDualSubtitle({
    super.key,
    required this.position,
    required this.currentPosition,
    required this.view,
    this.onTapCue,
  });

  /// 자막을 눌렀을 때. 자막 상자 밖의 클릭은 아래 조작부로 그대로 전달된다.
  final ValueChanged<BilingualCue>? onTapCue;

  /// 재생 위치 스트림 (player.stream.position)
  final Stream<Duration> position;

  /// 현재 재생 위치 (player.state.position) — 화면이 새로 만들어질 때 초기값
  final Duration Function() currentPosition;
  final DualSubtitleState view;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: view,
      builder: (context, _) => StreamBuilder<Duration>(
        stream: position,
        initialData: currentPosition(),
        builder: (context, snap) => DualSubtitleOverlay(
          cue: cueAt(
            view.cues,
            snap.data ?? Duration.zero,
            linger: lingerAfterCue,
          ),
          showOriginal: view.showOriginal,
          showTranslation: view.showTranslation,
          showVocab: view.showVocab,
          onTapCue: onTapCue,
        ),
      ),
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
    this.onTapCue,
  });

  final ValueChanged<BilingualCue>? onTapCue;
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
        final words = showVocab
            ? (c.words ?? const <VocabItem>[])
            : const <VocabItem>[];
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
                    if (showOriginal)
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
                        style: TextStyle(
                          fontSize: size,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          shadows: shadow,
                        ),
                      ),
                    if (showTranslation && c.translation != null) ...[
                      SizedBox(height: size * 0.15),
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
        // 학습 단어: 화면 위쪽에 자막처럼
        final vocab = IgnorePointer(
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
                      Text.rich(
                        TextSpan(
                          children: [
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

  /// 자막 상자만 클릭을 받는다. [onTapCue]가 없으면 클릭을 통과시킨다.
  Widget _tappable(BilingualCue c, Widget box) {
    final onTap = onTapCue;
    if (onTap == null) return IgnorePointer(child: box);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => onTap(c), child: box),
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
