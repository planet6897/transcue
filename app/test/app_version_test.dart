import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/app_version.dart';

void main() {
  test('앱 안 버전 표시가 pubspec.yaml 버전과 같다', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml에 version: X.Y.Z+빌드 가 있어야 한다');
    expect(appVersion, m![1]);
    expect(appBuild, int.parse(m[2]!));
  });

  test('CHANGELOG.md에 지금 버전 항목이 있다', () {
    final log = File('../CHANGELOG.md').readAsStringSync();
    expect(
      RegExp(
        '^## \\[${RegExp.escape(appVersion)}\\]',
        multiLine: true,
      ).hasMatch(log),
      isTrue,
      reason: 'CHANGELOG.md에 "## [$appVersion]" 항목을 추가하세요',
    );
  });
}
