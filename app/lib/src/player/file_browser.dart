import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'playlist.dart';

/// Android용 동영상 고르기.
///
/// 시스템 파일 선택기(file_selector)는 고른 파일을 앱 캐시로 **통째로 복사**해서
/// 경로를 준다 (수 GB 영상이면 느리고, 열 때마다 경로가 바뀌어 이어 보기·자막 저장이 안 됨).
/// 대신 동영상 읽기 권한을 받아 실제 경로를 직접 고른다.
Future<String?> pickVideoOnAndroid(
  BuildContext context, {
  String? startDir,
}) async {
  // Android 13+: 동영상 권한, 12 이하: 저장소 읽기 권한 (MainActivity.kt)
  const ch = MethodChannel('dualcue/permission');
  final granted = await ch.invokeMethod<bool>('requestVideo') ?? false;
  if (!granted) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('동영상을 열려면 사진 및 동영상 접근 권한이 필요합니다'),
          action: SnackBarAction(
            label: '설정',
            onPressed: () => ch.invokeMethod<void>('openSettings'),
          ),
        ),
      );
    }
    return null;
  }
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (_) => _FileBrowser(start: startDir ?? _root),
  );
}

const _root = '/storage/emulated/0';

class _FileBrowser extends StatefulWidget {
  const _FileBrowser({required this.start});
  final String start;

  @override
  State<_FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<_FileBrowser> {
  late String _dir = Directory(widget.start).existsSync()
      ? widget.start
      : _root;
  List<FileSystemEntity> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    List<FileSystemEntity> all;
    try {
      all = Directory(_dir).listSync();
    } on FileSystemException {
      all = const [];
    }
    String name(FileSystemEntity e) => e.path.split('/').last;
    // Android 저장소(FUSE)는 항목 종류를 알려 주지 않을 때가 있어(DT_UNKNOWN)
    // listSync 결과 타입만 믿으면 Movies 같은 폴더가 빠진다 → 직접 확인
    final dirs = <Directory>[];
    final files = <File>[];
    for (final e in all) {
      final n = name(e);
      if (n.startsWith('.')) continue;
      if (FileSystemEntity.isDirectorySync(e.path)) {
        dirs.add(Directory(e.path));
      } else if (isVideoFile(n)) {
        files.add(File(e.path));
      }
    }
    dirs.sort((a, b) => naturalCompare(name(a), name(b)));
    files.sort((a, b) => naturalCompare(name(a), name(b)));
    setState(() => _items = [...dirs, ...files]);
  }

  void _go(String dir) {
    _dir = dir;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final canUp = _dir != _root && _dir.contains('/');
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
      title: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward),
            onPressed: canUp
                ? () => _go(_dir.substring(0, _dir.lastIndexOf('/')))
                : null,
          ),
          Expanded(
            child: Text(
              _dir == _root ? '내장 저장공간' : _dir.split('/').last,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 480,
        height: 480,
        child: _items.isEmpty
            ? const Center(child: Text('동영상이 없습니다'))
            : ListView.builder(
                itemCount: _items.length,
                itemBuilder: (_, i) {
                  final e = _items[i];
                  final name = e.path.split('/').last;
                  final isDir = e is Directory;
                  return ListTile(
                    dense: true,
                    leading: Icon(isDir ? Icons.folder : Icons.movie),
                    title: Text(name),
                    onTap: () =>
                        isDir ? _go(e.path) : Navigator.pop(context, e.path),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
      ],
    );
  }
}
