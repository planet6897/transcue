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
4. macOS는 Release가 만들어지면 GitHub Actions(`.github/workflows/release-macos.yml`)가
   macOS 서버에서 빌드해 `transcue-X.Y.Z-macos-universal.zip`을 같은 Release에 붙인다 (Mac 불필요, 10분 안팎).
   실패했으면 Actions 탭에서 "Release (macOS)"를 태그를 넣어 다시 돌린다.
5. Linux도 같은 방식으로 GitHub Actions(`.github/workflows/release-linux.yml`)가 Ubuntu 서버에서 빌드해
   `transcue-X.Y.Z-linux-x64.tar.gz`를 같은 Release에 붙인다. 실패했으면 "Release (Linux)"를 다시 돌린다.

## 플랫폼별 산출물

| 플랫폼 | 파일 | 만드는 곳 |
|---|---|---|
| Windows 11 (x64) | `transcue-X.Y.Z-windows-x64.zip` | `release.ps1` (Windows PC) |
| macOS (Intel·Apple Silicon) | `transcue-X.Y.Z-macos-universal.zip` | GitHub Actions macOS 서버 |
| Linux (x64) | `transcue-X.Y.Z-linux-x64.tar.gz` | GitHub Actions Ubuntu 서버 |
| Android (64비트 ARM 권장) | `transcue-X.Y.Z-android.apk` | `release.ps1` (Windows PC) |

macOS 앱은 하나로 Intel(x86_64)과 Apple Silicon(arm64)에서 모두 돈다 (universal).
CI가 PR마다 macOS를 release로 빌드해 앱 안의 모든 실행 파일·라이브러리에 두 CPU가 다 있는지
`scripts/check-macos-universal.sh`로 확인한다.

## 참고

- Android APK는 아직 debug 키로 서명한다 (`app/android/app/build.gradle.kts`). 정식 배포 전에 배포용 키를 만들어야 한다.
- Windows는 설치본 없이 zip으로 배포한다 (Release 폴더 전체를 풀어 `transcue.exe` 실행).
- macOS 앱은 아직 Apple 개발자 서명·공증을 하지 않았다 (임시 서명만). 브라우저로 받은 zip은 macOS가 막으므로
  터미널 설치를 안내한다: `curl -fsSL https://raw.githubusercontent.com/planet6897/transcue/main/scripts/install-macos.sh | bash`
  (curl로 받은 파일은 "인터넷에서 받음" 표시가 없어 그대로 열린다). 이미 브라우저로 받았으면
  `xattr -cr /Applications/Transcue.app`. 경고를 완전히 없애려면 서명·공증이 필요하다 (#24).
- Linux는 설치본 없이 tar.gz로 배포한다 (풀어서 `transcue` 실행). 앱에 libmpv를 넣지 않으므로 쓰는 PC에
  mpv 라이브러리가 있어야 한다 (`sudo apt install libmpv2` 또는 `mpv`). 빌드한 Ubuntu보다 오래된 배포판에서는
  실행되지 않을 수 있다.
- 외부 도구(ffmpeg, whisper-cli, yt-dlp)는 각 PC에 설치한다. Linux는 `scripts/setup-linux.sh`. macOS는 Homebrew가 그 Mac의 CPU에 맞는 것을 설치한다
  (`brew install ffmpeg whisper-cpp yt-dlp`). whisper-cpp에는 Parakeet용 `parakeet-cli`도 함께 들어 있다.
  Homebrew의 whisper-cpp는 미리 빌드된 파일이 Apple Silicon용만 있어, Intel Mac에서는 설치할 때 소스부터 빌드한다(시간이 걸림).
