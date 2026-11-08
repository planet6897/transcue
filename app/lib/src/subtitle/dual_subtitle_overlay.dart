import 'package:flutter/material.dart';

import 'bilingual_cue.dart';

/// 영상 하단에 원문(위) + 한국어 번역(아래)을 겹쳐 보여주는 오버레이.
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

    const shadow = [Shadow(blurRadius: 4, color: Colors.black)];
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  style: const TextStyle(
                    fontSize: 26,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    shadows: shadow,
                  ),
                ),
              if (showTranslation && c.translation != null) ...[
                const SizedBox(height: 4),
                Text(
                  c.translation!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    color: Color(0xFFFFE082),
                    shadows: shadow,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
