# Transcue 프로젝트 계획

> **Transcue** (구 DualCue) — *Trans*cribe(음성 인식) + *Trans*late(AI 번역) + *Cue*(자막 한 줄·재생). 동영상의 음성을 자막으로 만들고, 번역해서
> 원문 자막 아래에 한국어 자막을 함께 보여주는 언어학습용 동영상 플레이어.

## 1. 목표 / 범위

| 단계 | 플랫폼 |
|---|---|
| 1차 | macOS, Windows |
| 2차 | iOS, Android (폰/태블릿) |

핵심 기능
1. 로컬 동영상 재생 (MP4, MKV, MOV, WebM 등 폭넓은 코덱) + **YouTube URL 재생**
2. 음성 → 원어 자막 생성 (STT)
3. 원어 자막 → 한국어 번역 (Claude / OpenAI / Gemini 중 선택)
4. 재생 중 **원문(위) + 번역(아래)** 이중 자막 오버레이
5. 학습 기능: 문장 단위 이동/반복(A-B 루프), 번역 숨기기, 자막 목록 패널, 속도 조절, 단어장
6. 내보내기: 원문/번역/이중 SRT, (선택) 자막을 영상에 입힌(burn-in) 파일

## 2. 기술 스택 선정

### 2.1 비교한 후보

| 후보 | 영상 재생 | 데스크톱→모바일 확장 | 평가 |
|---|---|---|---|
| **Flutter + media_kit(libmpv) + Rust 코어** | libmpv 기반, 코덱 폭넓음, 위젯 트리 안에 텍스처로 렌더 → 자막 오버레이 쉬움 | 같은 코드로 iOS/Android | **채택** |
| Tauri 2 (Rust + 웹 UI) | WebView 내장 `<video>`는 OS 코덱에 의존 (MKV 미지원, HEVC는 하드웨어 의존). libmpv 플러그인은 별도 창을 겹치는 방식, Windows 외 검증 부족 | 모바일 지원은 있으나 영상 재생 문제 동일 | 탈락: 재생 품질/코덱 리스크 |
| Electron | Chromium 코덱 한계 (MKV/HEVC 제한), 앱 용량 큼 | 모바일 불가 | 탈락 |
| Qt 6 / QML (FFmpeg 백엔드) | 매우 강력 | 가능 | 차선: C++ 생산성, 라이선스(LGPL/상용) 부담 |
| .NET MAUI / Avalonia + LibVLCSharp | 강력 (VLC) | MAUI는 데스크톱 품질 편차, Avalonia 모바일 미성숙 | 차선 |
| Compose Multiplatform | 데스크톱 영상 플레이어 미성숙 (VLCJ 의존) | 가능 | 탈락 |

**결정 이유**
- 이 앱의 핵심은 "영상 위에 커스텀 이중 자막을 정확히 겹쳐 그리기" → 영상이 UI 프레임워크 안에서 텍스처로 그려지는 Flutter+media_kit가 가장 단순.
- 무거운 작업(STT, 오디오 추출, 번역 배치, 캐시)은 **Rust 코어**에 두고 `flutter_rust_bridge`로 연결 → 나중에 UI를 바꿔도 코어 재사용 가능.
- whisper.cpp(`whisper-rs`)는 macOS/Windows/iOS/Android 모두 빌드 가능 (참고: `flutter_whisper.cpp` 예제 = Flutter + flutter_rust_bridge + whisper-rs).

**리스크와 대응**
- media_kit는 사실상 메인테이너 1인 → 플레이어를 `PlayerBackend` 인터페이스 뒤에 두어, 필요 시 공식 `video_player` 또는 포크로 교체 가능하게 설계.
- 모바일 FFmpeg 번들 (ffmpeg-kit 지원 종료) → 모바일에서는 media_kit/libmpv의 디코더나 플랫폼 API(AVFoundation/MediaCodec)로 오디오 추출하는 방안을 M6에서 검증.

### 2.2 사용할 오픈소스

| 영역 | 라이브러리 | 라이선스 |
|---|---|---|
| UI | Flutter | BSD-3 |
| 재생 | media_kit (libmpv) | MIT (libmpv LGPL) |
| Rust↔Dart | flutter_rust_bridge | MIT |
| STT (로컬) | whisper.cpp + whisper-rs, 모델 `large-v3-turbo` / `small`(저사양) | MIT |
| VAD | whisper.cpp 내장 Silero VAD | MIT |
| 오디오 추출 | FFmpeg (LGPL 빌드, 사이드카 바이너리) | LGPL-2.1 |
| YouTube | yt-dlp (사이드카 실행 파일, 자동 업데이트) | Unlicense |
| 캐시/단어장 | SQLite (`rusqlite`) | MIT/Public Domain |
| HTTP | `reqwest` + `tokio` | MIT/Apache |
| API 키 저장 | `keyring` (macOS Keychain / Windows Credential Manager) | MIT/Apache |

## 3. 아키텍처

```
┌──────────────────────── Flutter (app/) ────────────────────────┐
│  PlayerScreen ── media_kit Video ── DualSubtitleOverlay         │
│  SubtitleListPanel · Settings(공급자/모델/API키) · 진행률 UI      │
└───────────────▲───────────────────────────────┬────────────────┘
                │ flutter_rust_bridge (stream)   │
┌───────────────┴──────── Rust core (core/) ────▼────────────────┐
│ audio:   FFmpeg → 16kHz mono PCM                               │
│ stt:     whisper-rs (+VAD) → 단어 타임스탬프 → 문장 단위 큐 분할   │
│ translate: Translator trait → Claude / OpenAI / Gemini          │
│            배치 + 앞 문맥 + JSON {id,text} 응답 + 누락 재시도      │
│ cache:   SQLite (영상 해시 + 모델 + 언어 → 결과 재사용)            │
│ srt:     SRT/VTT 파싱·내보내기 (원문/번역/이중)                    │
└────────────────────────────────────────────────────────────────┘
```

> **현재 구현 상태:** 파이프라인(ffmpeg 음성 추출 → whisper-cli STT → Claude 번역 → 캐시)은 빠른 검증을 위해 Dart에서 외부 도구를 실행하는 방식으로 먼저 구현했다. Rust 코어(flutter_rust_bridge, whisper-rs)로 옮기는 작업은 M1 이슈로 진행한다.

처리 흐름
1. 영상 열기 → 파일 해시로 캐시 조회 → 있으면 바로 이중 자막 표시
2. 없으면: 내장/외부 자막 있으면 사용, 없으면 오디오 추출 → STT
3. STT 결과를 **앞부분부터 스트리밍**으로 번역 → 재생하면서 뒤쪽이 채워짐
4. 결과 SQLite 캐시 저장, 사용자가 SRT로 내보내기 가능

### YouTube 재생 흐름
1. URL에서 영상 ID 추출 → `yt-dlp -J`로 스트림/자막 정보 조회
2. 1080p 이하 최고 화질 영상 스트림 + 별도 음성 스트림을 media_kit로 재생 (없으면 통합 포맷)
3. YouTube가 제공하는 자막 활용 → **STT/번역 비용 0**
   - 원어: 수동 자막 → 자동 생성(`<언어>-orig`) 순
   - 한국어: 수동 한국어 자막 → YouTube 자동 번역(`ko`) 순. 설정에서 AI 번역으로 바꿀 수 있게 함(M3)
   - 자동 자막의 롤링 중복 줄은 WebVTT 파서에서 제거
   - 자막은 URL을 직접 받지 않고 yt-dlp로 받음 (자동 번역 자막은 VTT가 아닌 HLS 재생목록으로 내려옴)
   - **YouTube 자동 번역은 요청 제한(HTTP 429)이 잦아 보조 수단으로만 사용.** 실패하면 원문만 표시하고, 주 번역은 M3 AI 번역
4. 자막이 없으면 yt-dlp로 음성만 받아 STT 파이프라인으로 처리 (M2)

YouTube 관련 주의
- **이용약관:** YouTube 약관은 공식 플레이어 밖에서의 스트림 접근을 제한함. 비공개 개인 학습용으로 진행하고, 공개 배포·스토어 출시 전에 정책을 재검토 (모바일 스토어는 심사 거절 위험 → 공식 IFrame 플레이어 모드를 대안으로 검토)
- **잦은 사이트 변경:** yt-dlp를 앱 지원 폴더에 두고 실행 시 `-U`로 자동 업데이트 (번들 안에 두면 서명이 깨짐)
- 자동 자막에는 구두점이 거의 없음 → AI 번역 전에 문장 단위 재분할 필요 (M2 문장 분할 이슈와 연계)
- 스트림 URL은 몇 시간 뒤 만료 → 오래 일시정지했다가 재개할 때 다시 조회

번역 설계 메모
- 기본 공급자: Claude (`claude-haiku-5-5` 저비용 / `claude-sonnet-5-5` 고품질). OpenAI·Gemini는 설정에서 선택.
- 한 줄씩이 아닌 **20~40개 큐 단위 배치 + 직전 5개 큐 문맥**으로 번역해 자연스러움 확보.
- 출력은 큐 ID별 JSON으로 강제 → 줄 수 어긋남 방지, 누락 ID만 재요청.
- 용어집(인명/고유명사) 옵션, 번역 톤(구어체/존댓말) 옵션.
- 클라우드 STT 옵션(OpenAI transcribe, Gemini)도 같은 trait 패턴으로 추가 가능.

## 4. 마일스톤

| # | 이름 | 내용 | 완료 기준 |
|---|---|---|---|
| M0 | 프로젝트 세팅 | 저장소, 앱/코어 골격, CI, 이슈 템플릿 | ✅ 이 커밋 |
| M1 | 플레이어 MVP | 파일 열기/재생/탐색/속도, **YouTube 재생 + YouTube 자막(원문/자동 번역)**, 외부 SRT 로드, 이중 자막 오버레이, Rust 코어 연결(frb) | SRT 2개(원문/번역)로 이중 자막 재생 |
| M2 | 자막 생성 (STT) | FFmpeg 오디오 추출 (YouTube는 yt-dlp 음성), whisper-rs, 모델 다운로드 관리, 문장 분할, 진행률, 캐시 | 30분 영상 자막 자동 생성 |
| M3 | 번역 | Claude/OpenAI/Gemini 공급자, 배치·문맥·재시도, API 키 Keychain 저장, 스트리밍 번역 | 생성 자막 한국어 번역 표시 |
| M4 | 학습 UX | 문장 이동/반복, 자막 목록 패널, 번역 가리기, 단어 클릭 → 단어장, 단축키 | 학습 시나리오 사용성 테스트 |
| M5 | 배포 | macOS 서명/공증(DMG), Windows MSIX/설치본, 자동 업데이트, burn-in 내보내기 | 정식 v1.0 릴리스 |
| M6 | 모바일 | iOS/Android 빌드, 모바일 레이아웃, 온디바이스 STT 성능 검증 | 태블릿 베타 |

## 5. 저장소 구조

```
.
├── app/            # Flutter 앱 (macOS, Windows → 이후 iOS, Android)
├── core/           # Rust 코어 라이브러리 (dualcue_core)
├── docs/           # 계획/설계 문서
└── .github/        # CI, 이슈/PR 템플릿
```

## 6. 개발 규칙
- 브랜치: `main` 보호, 기능은 `feat/<이슈번호>-설명`, 버그는 `fix/...` → PR → CI 통과 후 병합
- 이슈: 템플릿(기능/버그) 사용, 마일스톤 + 영역 라벨(`area:*`) 지정
- 커밋: Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:` …)
