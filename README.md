# Transcue

**AI 동영상 플레이어.** 영상을 열면 AI가 음성을 받아 적고 번역해 **원어 자막과 한국어 자막을 함께** 보여 줍니다. 자막이 없는 영상도 그대로 언어 학습 교재가 됩니다.

- **AI 음성 인식:** whisper.cpp로 영상의 음성을 기기에서 직접 자막으로 만듭니다.
- **AI 번역:** Claude·OpenAI·Gemini 중 고른 AI가 앞뒤 문맥을 보고 한국어로 번역합니다.
- **AI 학습 단어:** 자막에서 수준에 맞는 단어를 골라 이 장면에서의 뜻을 보여 줍니다.
- **AI 자막 검증:** 내려받은 자막이 실제 음성과 맞는지 대조하고, 어긋난 싱크는 자동으로 보정합니다.

- 플랫폼: macOS, Windows, Linux, Android (예정: iOS)
- 스택: Flutter + media_kit(libmpv) · Rust 코어(whisper.cpp, FFmpeg) · Claude / OpenAI / Gemini 번역

자세한 계획은 [docs/PLAN.md](docs/PLAN.md) 참고.

## 설치

[Releases](https://github.com/planet6897/transcue/releases)에서 받는다.

- **macOS** (Intel·Apple Silicon): 터미널에서 아래 한 줄을 실행한다. `/Applications`에 설치된다.
  ```bash
  curl -fsSL https://raw.githubusercontent.com/planet6897/transcue/main/scripts/install-macos.sh | bash
  ```
  앱에 Apple 개발자 서명·공증이 없어서 브라우저로 받은 zip은 macOS가 열지 못하게 막는다.
  이미 브라우저로 받았다면 `xattr -cr /Applications/Transcue.app` 을 실행하면 열린다.
- **Windows**: `transcue-X.Y.Z-windows-x64.zip`을 풀고 `transcue.exe` 실행. 처음에 "Windows의 PC 보호"가 뜨면 추가 정보 → 실행.
- **Linux**: `transcue-X.Y.Z-linux-x64.tar.gz`를 풀고 `transcue` 실행 (mpv 라이브러리 필요: `sudo apt install libmpv2`).
- **Android**: `transcue-X.Y.Z-android.apk` 설치 (출처를 알 수 없는 앱 허용).

음성 인식·YouTube에는 외부 도구(ffmpeg, whisper.cpp, yt-dlp)가 필요하다 (아래 개발 환경의 설치 명령 참고).

## 사용법

영상을 여는 방법:

- **동영상 파일**: 메뉴의 동영상 열기 버튼으로 고르거나, 파일을 앱 창 위에 끌어다 놓는다.
- **YouTube**: 메뉴의 YouTube 열기 버튼을 누르고 주소를 붙여 넣는다.
  또는 **브라우저에서 YouTube 링크를 끌어서 앱 창 위에 놓는다** (주소창의 주소, 영상 썸네일·제목 링크 모두 된다).
  다른 영상을 보는 중에 놓아도 바로 그 영상으로 바뀐다.
- **영어 강연·학습 채널**: 메뉴의 채널 버튼에서 TED·BBC·VOA 영상을 골라 연다.

끌어다 놓기는 macOS·Windows·Linux에서 된다.

## 개발 환경

필요: Flutter 3.41+, 외부 도구 `brew install ffmpeg whisper-cpp yt-dlp` (Windows: `powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1`, Linux: `bash scripts/setup-linux.sh`), Rust 1.93 (`rust-toolchain.toml`로 고정), Xcode(macOS) / Visual Studio 2022 C++ 워크로드(Windows) / clang·cmake·ninja·GTK 3·libmpv(Linux, `setup-linux.sh`가 함께 설치)

Windows에서는 프로젝트를 **NTFS 드라이브**에 두고 **개발자 모드**를 켜야 합니다. Flutter 플러그인 빌드에 심볼릭 링크가 필요해서 exFAT/FAT32 드라이브에서는 빌드할 수 없습니다.

```bash
# 앱 실행
cd app && flutter run -d macos   # 또는 -d windows, -d linux

# 코어 테스트
cd core && cargo test
```

## 라이선스
MIT — 사용하는 오픈소스 라이선스는 [docs/PLAN.md](docs/PLAN.md#22-사용할-오픈소스) 참고.
