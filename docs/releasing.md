# 버전과 배포

## 버전 번호

`app/pubspec.yaml`의 `version: X.Y.Z+빌드` 하나가 기준이다. Android(`versionName`/`versionCode`)와
Windows 실행 파일 버전은 이 값을 그대로 쓰고, 앱 설정 화면 오른쪽 위에 `Transcue X.Y.Z (빌드 N)`으로 보인다.

- **X.Y.Z** ([유의적 버전](https://semver.org/lang/ko/)): 기능을 더하면 Y, 버그만 고치면 Z를 올린다.
  1.0.0 전까지는 0.Y.Z로 둔다.
- **빌드 번호**: 배포할 때마다 1씩 올린다. Android는 설치된 앱보다 빌드 번호가 작으면 업데이트할 수 없다.

앱 안 표시(`app/lib/src/app_version.dart`)와 `CHANGELOG.md`의 버전 항목이 pubspec과 다르면 테스트가 실패한다.

## 배포 순서

1. 바뀐 내용을 `CHANGELOG.md`의 `## [Unreleased]` 아래에 적어 둔다 (PR마다).
2. 버전을 올린다 → PR로 main에 넣는다.
   ```powershell
   powershell -File scripts/bump-version.ps1 0.10.0
   ```
   pubspec, `app_version.dart`, 빌드 번호(+1)를 바꾸고 `[Unreleased]` 내용을 `## [0.10.0] - 날짜`로 옮긴다.
3. main에서 배포한다.
   ```powershell
   powershell -File scripts/release.ps1 -DryRun   # 빌드와 묶기만 확인
   powershell -File scripts/release.ps1           # 태그 vX.Y.Z + GitHub Release
   ```
   테스트 → Windows·Android 릴리즈 빌드 → `dist/X.Y.Z/`에 `transcue-X.Y.Z-windows-x64.zip`,
   `transcue-X.Y.Z-android.apk` → 태그 → GitHub Release (설명은 CHANGELOG의 그 버전 항목).
   main이 origin과 다르거나, 같은 태그가 있거나, 커밋하지 않은 변경이 있으면 멈춘다.

## 참고

- Android APK는 아직 debug 키로 서명한다 (`app/android/app/build.gradle.kts`). 정식 배포 전에 배포용 키를 만들어야 한다.
- Windows는 설치본 없이 zip으로 배포한다 (Release 폴더 전체를 풀어 `transcue.exe` 실행).
