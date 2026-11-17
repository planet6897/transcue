import 'package:flutter/material.dart';

import '../subtitle/bilingual_cue.dart';
import '../subtitle/dual_subtitle_overlay.dart' show highlightSegments;
import '../translate/translator.dart';

/// 문장 해설 (AI): 짚어 볼 표현과 문장의 뉘앙스.
/// 해설과 함께 문장을 단어장에 저장할 수 있다.
class ExplainDialog extends StatelessWidget {
  const ExplainDialog({
    super.key,
    required this.cue,
    required this.explanation,
    required this.onSave,
  });

  final BilingualCue cue;
  final Future<Explanation> explanation;

  /// 해설을 붙여 문장을 단어장에 저장
  final ValueChanged<Explanation> onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final accent = theme.colorScheme.primary;
    return AlertDialog(
      title: const Text('문장 해설'),
      content: SizedBox(
        width: 560,
        child: FutureBuilder<Explanation>(
          future: explanation,
          builder: (context, snap) {
            final e = snap.data;
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        for (final (t, hl) in highlightSegments(cue.original, [
                          for (final p in e?.points ?? const []) p.phrase,
                        ]))
                          TextSpan(
                            text: t,
                            style: hl
                                ? TextStyle(
                                    color: accent,
                                    fontWeight: FontWeight.w700,
                                  )
                                : null,
                          ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 18),
                  ),
                  if (cue.translation != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        cue.translation!,
                        style: TextStyle(color: muted),
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (snap.hasError)
                    Text(
                      '해설을 받지 못했습니다: ${snap.error}',
                      style: TextStyle(color: theme.colorScheme.error),
                    )
                  else if (e == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    for (final p in e.points)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.phrase,
                              style: TextStyle(
                                color: accent,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(p.note, style: const TextStyle(height: 1.4)),
                          ],
                        ),
                      ),
                    if (e.nuance.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          e.nuance,
                          style: const TextStyle(height: 1.4),
                        ),
                      ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        FutureBuilder<Explanation>(
          future: explanation,
          builder: (context, snap) => TextButton.icon(
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('해설과 함께 단어장에 저장'),
            onPressed: snap.data == null
                ? null
                : () {
                    onSave(snap.data!);
                    Navigator.pop(context);
                  },
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
