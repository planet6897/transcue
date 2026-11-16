import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';
import '../settings/app_settings.dart';

/// 배포 저장소 (GitHub Releases)
const updateRepo = 'planet6897/transcue';

/// 배포된 파일 하나
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
  });
  final String name;
  final String url;
  final int size;
}

/// GitHub의 최신 배포
class LatestRelease {
  const LatestRelease({
    required this.version,
    required this.notes,
    required this.pageUrl,
    required this.assets,
  });

  /// "0.13.1" (태그의 v를 뺀 것)
  final String version;
  final String notes;
  final String pageUrl;
  final List<ReleaseAsset> assets;

  /// GitHub API `releases/latest` 응답 (테스트용으로 분리)
  static LatestRelease? fromJson(Map<String, dynamic> j) {
    final tag = j['tag_name'] as String?;
    if (tag == null || j['draft'] == true || j['prerelease'] == true) {
      return null;
    }
    return LatestRelease(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      notes: j['body'] as String? ?? '',
      pageUrl:
          j['html_url'] as String? ?? 'https://github.com/$updateRepo/releases',
      assets: [
        for (final a in (j['assets'] as List? ?? []).cast<Map>())
          ReleaseAsset(
            name: '${a['name']}',
            url: '${a['browser_download_url']}',
            size: (a['size'] as num?)?.toInt() ?? 0,
          ),
      ],
    );
  }

  /// 이 기기에 맞는 파일 (없으면 null → 배포 페이지를 연다)
  ReleaseAsset? assetFor({required bool windows, required bool android}) {
    final suffix = windows
        ? '-windows-x64.zip'
        : android
        ? '-android.apk'
        : null;
    if (suffix == null) return null;
    return assets.where((a) => a.name.endsWith(suffix)).firstOrNull;
  }
}

/// 버전 비교 ("0.13.0" < "0.13.1" < "0.14.0"). 숫자가 아닌 부분은 0으로 본다.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split('-').first.split('.')) int.tryParse(p) ?? 0,
  ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// 이 기기에서 앱이 스스로 새 버전을 설치할 수 있는지
/// (Windows: 앱 폴더에 쓸 수 있을 때, Android: 설치 화면을 띄운다. macOS·Linux는 배포 페이지를 연다)
bool get canSelfUpdate {
  if (Platform.isAndroid) return true;
  if (!Platform.isWindows) return false;
  try {
    final probe = File('${_appDir.path}${Platform.pathSeparator}.update_probe');
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false; // Program Files 등 관리자 권한이 필요한 곳
  }
}

Directory get _appDir => File(Platform.resolvedExecutable).parent;

const _channel = MethodChannel('transcue/update');

/// 업데이트 확인 기록 (너무 자주 묻지 않게, 건너뛴 버전)
class _UpdateMemo {
  _UpdateMemo(this.lastCheck, this.skipped);
  DateTime? lastCheck;
  String? skipped;

  static Future<File> _file() async =>
      File('${(await AppSettings.supportDir()).path}/update.json');

  static Future<_UpdateMemo> load() async {
    try {
      final j = jsonDecode(await (await _file()).readAsString()) as Map;
      return _UpdateMemo(
        DateTime.tryParse('${j['lastCheck']}'),
        j['skipped'] as String?,
      );
    } catch (_) {
      return _UpdateMemo(null, null);
    }
  }

  Future<void> save() async {
    try {
      await (await _file()).writeAsString(
        jsonEncode({
          'lastCheck': ?lastCheck?.toIso8601String(),
          'skipped': ?skipped,
        }),
      );
    } catch (_) {}
  }
}

/// GitHub에서 최신 배포를 가져온다. 실패하면 null.
Future<LatestRelease?> fetchLatestRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(
      Uri.parse('https://api.github.com/repos/$updateRepo/releases/latest'),
    );
    req.headers
      ..set(HttpHeaders.userAgentHeader, 'transcue-app')
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 15));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      debugPrint('[update] GitHub ${res.statusCode}');
      return null;
    }
    return LatestRelease.fromJson(jsonDecode(body) as Map<String, dynamic>);
  } on Exception catch (e) {
    debugPrint('[update] check failed: $e');
    return null;
  } finally {
    client.close();
  }
}

/// 새 버전이 있으면 돌려준다.
/// [force]가 아니면 12시간에 한 번만 확인하고, 건너뛰기로 한 버전은 알리지 않는다.
Future<LatestRelease?> checkForUpdate({bool force = false}) async {
  final memo = await _UpdateMemo.load();
  final now = DateTime.now();
  if (!force &&
      memo.lastCheck != null &&
      now.difference(memo.lastCheck!) < const Duration(hours: 12)) {
    return null;
  }
  final r = await fetchLatestRelease();
  if (r == null) return null;
  memo.lastCheck = now;
  await memo.save();
  debugPrint('[update] latest ${r.version}, this $appVersion');
  if (compareVersions(r.version, appVersion) <= 0) return null;
  if (!force && memo.skipped == r.version) return null;
  return r;
}

/// 이 버전은 다시 알리지 않는다
Future<void> skipVersion(String version) async {
  final memo = await _UpdateMemo.load();
  memo.skipped = version;
  await memo.save();
}

/// 배포 파일을 받는다. [onProgress]는 0~1.
Future<File> downloadAsset(
  ReleaseAsset asset, {
  void Function(double)? onProgress,
}) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
  await dir.create(recursive: true);
  final file = File('${dir.path}/${asset.name}');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(asset.url));
    req.headers.set(HttpHeaders.userAgentHeader, 'transcue-app');
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('다운로드 실패 (HTTP ${res.statusCode})');
    }
    final total = res.contentLength > 0 ? res.contentLength : asset.size;
    final sink = file.openWrite();
    var got = 0;
    try {
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress?.call(got / total);
      }
    } finally {
      await sink.close();
    }
    if (total > 0 && got != total) {
      throw HttpException('다운로드가 끊겼습니다 ($got/$total)');
    }
    return file;
  } finally {
    client.close();
  }
}

/// 받은 파일로 설치한다.
/// Windows: 앱을 닫고 파일을 바꾼 뒤 다시 실행하는 스크립트를 띄우고 앱을 끝낸다.
/// Android: 설치 화면을 연다 (처음이면 '이 앱의 설치 허용' 설정 화면). 설치 화면을 열었으면 true.
Future<bool> installUpdate(File file) async {
  if (Platform.isAndroid) {
    final r = await _channel.invokeMethod<String>('install', {
      'path': file.path,
    });
    return r == 'started';
  }
  if (Platform.isWindows) {
    final script = File('${file.parent.path}\\transcue-update.ps1');
    await script.writeAsString(_windowsScript);
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
      '-ProcId',
      '$pid',
      '-Zip',
      file.path,
      '-Dest',
      _appDir.path,
      '-Exe',
      Platform.resolvedExecutable,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }
  return false;
}

/// 브라우저로 주소를 연다 (macOS·Linux 업데이트, 설치에 실패했을 때)
Future<void> openUrl(String url) async {
  try {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openUrl', {'url': url});
    } else if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url]);
    } else {
      await Process.start('xdg-open', [url]);
    }
  } on Exception catch (e) {
    debugPrint('[update] open $url failed: $e');
  }
}

/// 앱이 끝나기를 기다렸다가 zip을 풀어 앱 폴더에 덮어쓰고 다시 실행한다.
/// 실패해도 원래 앱은 다시 실행한다. (Windows PowerShell 5.1은 BOM 없는 UTF-8을
/// 잘못 읽으므로 ASCII만 쓴다. 기록은 %TEMP%\transcue-update.log)
const _windowsScript = r'''
param([int]$ProcId, [string]$Zip, [string]$Dest, [string]$Exe)
$log = Join-Path $env:TEMP 'transcue-update.log'
function Log($m) { Add-Content -Path $log -Value ("{0:s} {1}" -f (Get-Date), $m) }
try {
  Log "update start pid=$ProcId zip=$Zip dest=$Dest"
  try { Wait-Process -Id $ProcId -Timeout 60 -ErrorAction Stop } catch {}
  Start-Sleep -Milliseconds 700
  $tmp = Join-Path $env:TEMP ('transcue-update-' + [guid]::NewGuid())
  Expand-Archive -LiteralPath $Zip -DestinationPath $tmp -Force
  Copy-Item -Path (Join-Path $tmp '*') -Destination $Dest -Recurse -Force
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $Zip -Force -ErrorAction SilentlyContinue
  Log 'update done'
} catch {
  Log ("update failed: " + $_)
}
try {
  $p = Start-Process -FilePath $Exe -WorkingDirectory $Dest -PassThru
  Log ("relaunched pid=" + $p.Id)
} catch {
  Log ("relaunch failed: " + $_)
}
''';
