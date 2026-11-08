# DualCue

동영상의 음성을 자막으로 만들고(STT), AI로 번역해 **원어 자막과 한국어 자막을 함께** 보여주는 언어학습용 동영상 플레이어.

- 플랫폼: macOS, Windows (예정: iOS, Android)
- 스택: Flutter + media_kit(libmpv) · Rust 코어(whisper.cpp, FFmpeg) · Claude / OpenAI / Gemini 번역

자세한 계획은 [docs/PLAN.md](docs/PLAN.md) 참고.

## 개발 환경

필요: Flutter 3.41+, Rust 1.93 (`rust-toolchain.toml`로 고정), Xcode(macOS) / Visual Studio 2022 C++ 워크로드(Windows)

```bash
# 앱 실행
cd app && flutter run -d macos   # 또는 -d windows

# 코어 테스트
cd core && cargo test
```

## 라이선스
MIT — 사용하는 오픈소스 라이선스는 [docs/PLAN.md](docs/PLAN.md#22-사용할-오픈소스) 참고.
