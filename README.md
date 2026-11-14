# Transcue

**AI 동영상 플레이어.** 영상을 열면 AI가 음성을 받아 적고 번역해 **원어 자막과 한국어 자막을 함께** 보여 줍니다. 자막이 없는 영상도 그대로 언어 학습 교재가 됩니다.

- **AI 음성 인식:** whisper.cpp로 영상의 음성을 기기에서 직접 자막으로 만듭니다.
- **AI 번역:** Claude·OpenAI·Gemini 중 고른 AI가 앞뒤 문맥을 보고 한국어로 번역합니다.
- **AI 학습 단어:** 자막에서 수준에 맞는 단어를 골라 이 장면에서의 뜻을 보여 줍니다.
- **AI 자막 검증:** 내려받은 자막이 실제 음성과 맞는지 대조하고, 어긋난 싱크는 자동으로 보정합니다.

- 플랫폼: macOS, Windows, Android (예정: iOS)
- 스택: Flutter + media_kit(libmpv) · Rust 코어(whisper.cpp, FFmpeg) · Claude / OpenAI / Gemini 번역

자세한 계획은 [docs/PLAN.md](docs/PLAN.md) 참고.

## 개발 환경

필요: Flutter 3.41+, 외부 도구 `brew install ffmpeg whisper-cpp yt-dlp` (Windows: `powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1`), Rust 1.93 (`rust-toolchain.toml`로 고정), Xcode(macOS) / Visual Studio 2022 C++ 워크로드(Windows)

Windows에서는 프로젝트를 **NTFS 드라이브**에 두고 **개발자 모드**를 켜야 합니다. Flutter 플러그인 빌드에 심볼릭 링크가 필요해서 exFAT/FAT32 드라이브에서는 빌드할 수 없습니다.

```bash
# 앱 실행
cd app && flutter run -d macos   # 또는 -d windows

# 코어 테스트
cd core && cargo test
```

## 라이선스
MIT — 사용하는 오픈소스 라이선스는 [docs/PLAN.md](docs/PLAN.md#22-사용할-오픈소스) 참고.
