import 'package:flutter/material.dart';

import 'bilingual_cue.dart';

/// 자막 표시 상태 (현재 자막 목록 + 원문/번역 표시 여부).
/// 전체 화면은 별도 화면(route)이라 부모 setState가 닿지 않으므로,
/// 오버레이가 이 객체와 재생 위치를 직접 구독한다.
class DualSubtitleState extends ChangeNotifier {
  List<BilingualCue> _cues = const [];
  bool _showOriginal = true;
  bool _showTranslation = true;

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
  });

  /// 재생 위치 스트림 (player.stream.position)
  final Stream<Duration> position;

  /// 현재 재생 위치 (player.state.position) — 화면이 새로 만들어질 때 초기값
  final Duration Function() currentPosition;
  final DualSubtitleState view;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListenableBuilder(
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
          ),
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
  });

  final BilingualCue? cue;
  final bool showOriginal;
  final bool showTranslation;

  @override
  Widget build(BuildContext context) {
    final c = cue;
    if (c == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight.isFinite ? box.maxHeight : 600.0;
        final size = (h * 0.038).clamp(16.0, 48.0);
        final shadow = [Shadow(blurRadius: size * 0.2, color: Colors.black)];
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            // 하단 재생 컨트롤 막대와 겹치지 않도록 여유를 둔다
            padding: EdgeInsets.fromLTRB(
              24,
              0,
              24,
              (h * 0.09).clamp(48.0, 110.0),
            ),
            child: Container(
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
                    Text(
                      c.original,
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
        );
      },
    );
  }
}
