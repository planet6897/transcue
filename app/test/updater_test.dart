import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/update/updater.dart';

void main() {
  test('버전 비교', () {
    expect(compareVersions('0.13.1', '0.13.0'), greaterThan(0));
    expect(compareVersions('0.14.0', '0.13.9'), greaterThan(0));
    expect(compareVersions('1.0.0', '0.99.99'), greaterThan(0));
    expect(compareVersions('0.13.0', '0.13.0'), 0);
    expect(compareVersions('0.12.3', '0.13.0'), lessThan(0));
  });

  group('LatestRelease.fromJson', () {
    final json = {
      'tag_name': 'v0.13.1',
      'body': '### 수정\n- 무엇',
      'html_url': 'https://github.com/x/y/releases/tag/v0.13.1',
      'assets': [
        {
          'name': 'transcue-0.13.1-windows-x64.zip',
          'browser_download_url': 'https://dl/win.zip',
          'size': 31000000,
        },
        {
          'name': 'transcue-0.13.1-android.apk',
          'browser_download_url': 'https://dl/app.apk',
          'size': 98000000,
        },
      ],
    };

    test('태그의 v를 빼고 기기에 맞는 파일을 고른다', () {
      final r = LatestRelease.fromJson(json)!;
      expect(r.version, '0.13.1');
      expect(
        r.assetFor(windows: true, android: false)?.url,
        'https://dl/win.zip',
      );
      expect(
        r.assetFor(windows: false, android: true)?.url,
        'https://dl/app.apk',
      );
      // macOS·Linux는 배포 페이지를 연다
      expect(r.assetFor(windows: false, android: false), isNull);
    });

    test('초안·미리보기 배포는 알리지 않는다', () {
      expect(LatestRelease.fromJson({...json, 'draft': true}), isNull);
      expect(LatestRelease.fromJson({...json, 'prerelease': true}), isNull);
    });
  });
}
