import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_version.dart';
import 'updater.dart';

/// 새 버전 안내 → 받기 → 설치.
/// Windows는 받은 뒤 앱을 다시 시작하고, Android는 설치 화면을 연다.
/// macOS·Linux는 배포 페이지를 연다.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.release});

  final LatestRelease release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  /// 받는 중이면 0~1, 아니면 null
  double? _progress;
  String? _error;
  bool _installing = false;

  ReleaseAsset? get _asset => canSelfUpdate
      ? widget.release.assetFor(
          windows: Platform.isWindows,
          android: Platform.isAndroid,
        )
      : null;

  Future<void> _update() async {
    final asset = _asset;
    if (asset == null) {
      await openUrl(widget.release.pageUrl);
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final file = await downloadAsset(
        asset,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _installing = true);
      final started = await installUpdate(file); // Windows는 여기서 앱이 끝난다
      if (!mounted) return;
      if (started) {
        Navigator.pop(context);
      } else {
        setState(() {
          _progress = null;
          _installing = false;
          _error = Platform.isAndroid
              ? "설치를 허용한 뒤 다시 '업데이트'를 누르세요"
              : '설치하지 못했습니다';
        });
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _installing = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final busy = _progress != null;
    final asset = _asset;
    final size = asset == null
        ? ''
        : ' (${(asset.size / 1024 / 1024).toStringAsFixed(0)}MB)';
    return AlertDialog(
      title: Text('새 버전 ${r.version}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('지금 버전: $appVersion'),
            const SizedBox(height: 12),
            if (r.notes.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: Text(
                    r.notes,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (busy) ...[
              LinearProgressIndicator(value: _installing ? null : _progress),
              const SizedBox(height: 6),
              Text(
                _installing
                    ? Platform.isWindows
                          ? '설치를 위해 앱을 다시 시작합니다…'
                          : '설치 화면을 여는 중…'
                    : '받는 중 ${((_progress ?? 0) * 100).toStringAsFixed(0)}%$size',
              ),
            ] else if (asset == null)
              const Text('배포 페이지에서 새 버전을 받으세요'),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!busy) ...[
          TextButton(
            onPressed: () {
              unawaited(skipVersion(r.version));
              Navigator.pop(context);
            },
            child: const Text('이 버전 건너뛰기'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: _update,
            child: Text(asset == null ? '배포 페이지 열기' : '업데이트$size'),
          ),
        ],
      ],
    );
  }
}
