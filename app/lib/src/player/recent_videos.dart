import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../source/youtube_url.dart';
import 'resume.dart';

/// 최근에 연 영상 하나. [source]는 파일 경로 또는 YouTube 주소.
class RecentVideo {
  const RecentVideo({required this.source, required this.title});

  final String source;
  final String title;

  Map<String, String> toJson() => {'source': source, 'title': title};

  factory RecentVideo.fromJson(Map<String, dynamic> j) => RecentVideo(
    source: j['source'] as String,
    title: j['title'] as String? ?? '',
  );
}

/// 최근에 연 영상 목록 (recent.json). 맨 앞이 가장 최근이다.
class RecentVideos {
  RecentVideos(this._file);

  static const maxEntries = 100;

  final File _file;
  final _items = <RecentVideo>[];
  bool _loaded = false;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = jsonDecode(await _file.readAsString()) as List;
      _items.addAll(j.cast<Map<String, dynamic>>().map(RecentVideo.fromJson));
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await _file.writeAsString(jsonEncode(_items));
    } catch (_) {}
  }

  Future<List<RecentVideo>> list() async {
    await _load();
    return List.unmodifiable(_items);
  }

  /// 목록 맨 앞에 넣는다. 이미 있으면 맨 앞으로 옮긴다.
  Future<void> add(String source, String title) async {
    await _load();
    _items
      ..removeWhere((v) => v.source == source)
      ..insert(0, RecentVideo(source: source, title: title));
    if (_items.length > maxEntries) {
      _items.removeRange(maxEntries, _items.length);
    }
    await _save();
  }

  Future<void> remove(String source) async {
    await _load();
    _items.removeWhere((v) => v.source == source);
    await _save();
  }
}

/// 목록에 보여 줄 한 줄
class RecentRow {
  const RecentRow({
    required this.video,
    this.resumeAt,
    this.playCount = 0,
    this.available = true,
  });

  final RecentVideo video;
  final Duration? resumeAt;
  final int playCount;

  /// 파일이 지금도 있는지
  final bool available;

  String get detail => [
    if (!available) '파일을 찾을 수 없음',
    if (resumeAt != null) '${formatPosition(resumeAt!)}부터 이어 보기',
    if (playCount > 0) '재생 $playCount회',
  ].join(' · ');
}

/// 최근 재생목록. 고른 영상의 source를 돌려준다.
/// 최근 재생목록 아이콘: TED 강연 / 다른 YouTube 영상 / 내 파일.
/// TED는 상단 메뉴의 TED 버튼과 같은 아이콘이다.
IconData recentIcon(RecentVideo v) {
  if (parseYoutubeId(v.source) == null) return Icons.movie_outlined;
  // "제목 | 강연자 | TED", "| TEDxSeoul", "| TED Countdown"
  return RegExp(r'\| TED[\w -]*$').hasMatch(v.title.trim())
      ? Icons.record_voice_over
      : Icons.smart_display;
}

class RecentVideosDialog extends StatefulWidget {
  const RecentVideosDialog({
    super.key,
    required this.rows,
    required this.onRemove,
  });

  final List<RecentRow> rows;
  final ValueChanged<String> onRemove;

  @override
  State<RecentVideosDialog> createState() => _RecentVideosDialogState();
}

class _RecentVideosDialogState extends State<RecentVideosDialog> {
  late final _rows = [...widget.rows];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('최근 재생목록'),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 560,
        height: 420,
        child: _rows.isEmpty
            ? const Center(child: Text('아직 재생한 영상이 없습니다'))
            : ListView.builder(
                itemCount: _rows.length,
                itemBuilder: (context, i) {
                  final row = _rows[i];
                  final detail = row.detail;
                  return ListTile(
                    enabled: row.available,
                    leading: Icon(recentIcon(row.video)),
                    title: Text(
                      row.video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: detail.isEmpty ? null : Text(detail),
                    onTap: () => Navigator.pop(context, row.video.source),
                    trailing: IconButton(
                      tooltip: '목록에서 지우기',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        widget.onRemove(row.video.source);
                        setState(() => _rows.removeAt(i));
                      },
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
