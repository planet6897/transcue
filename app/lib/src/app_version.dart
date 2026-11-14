/// 앱 버전. pubspec.yaml의 `version: X.Y.Z+빌드`와 같아야 한다
/// (test/app_version_test.dart가 확인하고, scripts/bump-version.ps1이 함께 바꾼다).
const appVersion = '0.10.0';

/// 빌드 번호 (Android versionCode). 배포할 때마다 1씩 올린다.
const appBuild = 4;

/// 화면에 보여 줄 버전 ("0.9.0 (빌드 2)")
const appVersionLabel = '$appVersion (빌드 $appBuild)';
