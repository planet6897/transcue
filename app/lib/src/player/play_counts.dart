import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// 영상별로 끝까지 재생한 횟수를 기억한다 (play_counts.json).
/// 키는 이어 보기와 같은 [PlaybackPositions.keyForPath] 형식을 쓴다.
class PlayCounts {
  PlayCounts(this._file);

  final File _file;
  final Map<String, int> _map = {};
  bool _loaded = false;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      for (final e in j.entries) {
        _map[e.key] = (e.value as num).toInt();
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await _file.writeAsString(jsonEncode(_map));
    } catch (_) {}
  }

  Future<int> get(String key) async {
    await _load();
    return _map[key] ?? 0;
  }

  /// 한 번 더 재생했음을 기록하고 새 횟수를 돌려준다.
  Future<int> increment(String key) async {
    await _load();
    final n = (_map[key] ?? 0) + 1;
    _map[key] = n;
    await _save();
    return n;
  }

  Future<void> reset(String key) async {
    await _load();
    if (_map.remove(key) != null) await _save();
  }
}

/// 영상 위에 띄우는 재생 횟수 표시와 리셋 버튼.
/// 전체 화면은 별도 화면이라 setState가 닿지 않으므로 [info]를 직접 구독한다.
class PlayCountBadge extends StatelessWidget {
  const PlayCountBadge({super.key, required this.info, required this.onReset});

  final ValueNotifier<({bool repeat, int count})> info;
  final VoidCallback onReset;

  static const _accent = Color(0xFF80DEEA);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: info,
      builder: (context, v, _) {
        if (!v.repeat && v.count == 0) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.center,
          child: Container(
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              color: const Color(0x99000000),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  v.repeat ? Icons.repeat_one : Icons.replay,
                  size: 16,
                  color: v.repeat ? _accent : Colors.white70,
                ),
                const SizedBox(width: 6),
                Text(
                  '재생 ${v.count}회',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    decoration: TextDecoration.none,
                  ),
                ),
                // 버튼으로 만들면 포커스를 가져가 Space/Enter 단축키를 빼앗는다
                Tooltip(
                  message: '재생 횟수 초기화 (Shift+R)',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onReset,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.restart_alt,
                          size: 18,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
