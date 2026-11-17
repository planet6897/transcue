import 'package:flutter/material.dart';

import '../player/resume.dart' show formatPosition;
import '../subtitle/dual_subtitle_overlay.dart' show highlightSegments;
import 'wordbook.dart';

const _accent = Color(0xFF80DEEA);

enum _Filter {
  all('전체'),
  words('단어'),
  sentences('문장');

  const _Filter(this.label);
  final String label;
}

/// 단어장: 모아 둔 단어·문장을 보고, 그 장면을 다시 재생하거나 빼거나 CSV로 내보낸다.
/// 다시 재생할 항목을 고르면 그 항목을 돌려준다.
class WordbookDialog extends StatefulWidget {
  const WordbookDialog({super.key, required this.book, required this.onExport});

  final Wordbook book;

  /// CSV 내보내기 (저장한 곳 또는 실패 사유를 알린다)
  final Future<void> Function(List<StudyItem>) onExport;

  @override
  State<WordbookDialog> createState() => _WordbookDialogState();
}

class _WordbookDialogState extends State<WordbookDialog> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: size.height * 0.9,
        ),
        child: ListenableBuilder(
          listenable: widget.book,
          builder: (context, _) {
            final all = widget.book.items;
            final items = switch (_filter) {
              _Filter.all => all,
              _Filter.words => [
                for (final e in all)
                  if (e.isWord) e,
              ],
              _Filter.sentences => [
                for (final e in all)
                  if (!e.isWord) e,
              ],
            };
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                  child: Row(
                    children: [
                      Text(
                        '단어장',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          children: [
                            for (final f in _Filter.values)
                              ChoiceChip(
                                label: Text('${f.label} ${_count(all, f)}'),
                                selected: _filter == f,
                                onSelected: (_) => setState(() => _filter = f),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'CSV로 내보내기 (엑셀·Anki)',
                        icon: const Icon(Icons.file_download_outlined),
                        onPressed: items.isEmpty
                            ? null
                            : () => widget.onExport(items),
                      ),
                      IconButton(
                        tooltip: '닫기',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: items.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            '아직 모은 것이 없습니다.\n\n'
                            '영상을 보다가 S 키(또는 자막 목록의 책갈피)로 문장을,\n'
                            '학습 단어(V)를 켠 뒤 단어를 눌러 단어를 모을 수 있습니다.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: items.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, indent: 16),
                          itemBuilder: (context, i) => _tile(items[i]),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static int _count(List<StudyItem> all, _Filter f) => switch (f) {
    _Filter.all => all.length,
    _Filter.words => all.where((e) => e.isWord).length,
    _Filter.sentences => all.where((e) => !e.isWord).length,
  };

  Widget _tile(StudyItem it) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: () => Navigator.pop(context, it),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (it.isWord)
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: it.word,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 17,
                            ),
                          ),
                          TextSpan(
                            text: '  ${it.pos ?? ''}  ',
                            style: TextStyle(color: muted),
                          ),
                          TextSpan(text: it.meaning ?? ''),
                        ],
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.only(top: it.isWord ? 4 : 0),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          for (final (t, hl) in highlightSegments(it.sentence, [
                            if (it.surface != null) it.surface!,
                          ]))
                            TextSpan(
                              text: t,
                              style: hl
                                  ? TextStyle(
                                      color: theme.brightness == Brightness.dark
                                          ? _accent
                                          : theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    )
                                  : null,
                            ),
                        ],
                      ),
                      style: TextStyle(
                        fontSize: it.isWord ? 14 : 16,
                        color: it.isWord ? muted : null,
                      ),
                    ),
                  ),
                  if (it.translation != null)
                    Text(
                      it.translation!,
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                  if (it.note != null)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        it.note!,
                        style: const TextStyle(fontSize: 13, height: 1.4),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    '${it.title}  ·  ${formatPosition(it.start)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '이 장면 다시 보기',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => Navigator.pop(context, it),
            ),
            IconButton(
              tooltip: '단어장에서 빼기',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => widget.book.remove(it),
            ),
          ],
        ),
      ),
    );
  }
}
