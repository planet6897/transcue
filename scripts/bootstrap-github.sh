#!/usr/bin/env bash
# GitHub 저장소 생성 + 라벨/마일스톤/초기 이슈 등록 (최초 1회 실행)
set -euo pipefail
REPO="${REPO:-planet6897/transcue}"
VISIBILITY="${VISIBILITY:---private}"   # 공개하려면 VISIBILITY=--public

cd "$(dirname "$0")/.."
gh repo view "$REPO" >/dev/null 2>&1 || gh repo create "$REPO" $VISIBILITY --source . --push \
  --description "원문+한국어 이중 자막 언어학습 동영상 플레이어 (STT + AI 번역)"

label() { gh label create "$1" --color "$2" --description "$3" -R "$REPO" --force; }
label "type:feature" 1d76db "새 기능"
label "type:bug"     d73a4a "버그"
label "type:chore"   cfd3d7 "설정/빌드/잡무"
label "area:player"  5319e7 "재생/오버레이 UI"
label "area:stt"     0e8a16 "음성 인식"
label "area:translate" fbca04 "번역 공급자"
label "area:core"    b60205 "Rust 코어"
label "area:learning" c5def5 "학습 기능"
label "area:release" 006b75 "패키징/배포"
label "area:youtube" ff0000 "YouTube 재생/자막"
label "platform:mobile" f9d0c4 "iOS/Android"

ms() { gh api "repos/$REPO/milestones" -f title="$1" -f description="$2" --silent 2>/dev/null || true; }
ms "M1 플레이어 MVP"  "파일 열기/재생, SRT 로드, 이중 자막, Rust 코어 연결"
ms "M2 자막 생성(STT)" "FFmpeg 오디오 추출, whisper-rs, 캐시"
ms "M3 번역"          "Claude/OpenAI/Gemini, 배치/문맥, API 키 저장"
ms "M4 학습 UX"       "문장 반복, 자막 목록, 단어장, 단축키"
ms "M5 배포"          "서명/공증, 설치본, 자동 업데이트, burn-in"
ms "M6 모바일"        "iOS/Android, 태블릿 레이아웃"

issue() { gh issue create -R "$REPO" --title "$1" --milestone "$2" --label "$3" --body "$4" >/dev/null && echo "  + $1"; }
issue "flutter_rust_bridge로 Rust 코어 연결" "M1 플레이어 MVP" "type:feature,area:core" "core/ 크레이트를 frb로 app/에 연결하고 Dart 임시 모델(BilingualCue)을 교체"
issue "외부 SRT 로드 (원문/번역 각각)" "M1 플레이어 MVP" "type:feature,area:player" "원문 SRT + 번역 SRT를 시간 기준으로 합쳐 이중 자막으로 표시"
issue "재생 컨트롤: 탐색/속도/키보드 단축키" "M1 플레이어 MVP" "type:feature,area:player" "Space 재생, ←/→ 문장 이동, 0.5~2.0x 속도"
issue "자막 스타일 설정 (크기/색/위치)" "M1 플레이어 MVP" "type:feature,area:player" "원문/번역 각각 글꼴 크기·색·배경 투명도"
issue "PlayerBackend 추상화" "M1 플레이어 MVP" "type:chore,area:player" "media_kit 교체 가능성 대비 인터페이스 분리"
issue "YouTube 재생 실기기 검증 (yt-dlp + media_kit)" "M1 플레이어 MVP" "type:chore,area:youtube" "macOS 샌드박스에서 yt-dlp 실행, 분리 음성 트랙 싱크, 자막 병합 확인"
issue "yt-dlp 번들 + 자동 업데이트" "M1 플레이어 MVP" "type:feature,area:youtube" "앱 지원 폴더에 단독 실행 파일 다운로드, 실행 시 -U"
issue "YouTube 스트림 URL 만료 시 재조회" "M1 플레이어 MVP" "type:feature,area:youtube" "403 감지 → 같은 위치로 다시 열기"
issue "YouTube 자막 원문/번역 트랙 선택 UI" "M1 플레이어 MVP" "type:feature,area:youtube" "언어 선택, YouTube 자동 번역 ↔ AI 번역 전환"
issue "자막 없는 YouTube 영상: 음성 받아 STT" "M2 자막 생성(STT)" "type:feature,area:youtube,area:stt" "yt-dlp -f bestaudio → STT 파이프라인"
issue "FFmpeg 사이드카로 16kHz mono 오디오 추출" "M2 자막 생성(STT)" "type:feature,area:stt" "LGPL 빌드 번들, 진행률 보고"
issue "whisper-rs 통합 + VAD" "M2 자막 생성(STT)" "type:feature,area:stt" "단어 타임스탬프, 언어 자동 감지, Metal/CUDA 가속 옵션"
issue "Whisper 모델 다운로드 관리" "M2 자막 생성(STT)" "type:feature,area:stt" "large-v3-turbo / small 선택, 체크섬 검증, 이어받기"
issue "문장 단위 큐 분할" "M2 자막 생성(STT)" "type:feature,area:core" "구두점/무음 기준, 최대 길이·표시 시간 제한"
issue "SQLite 결과 캐시" "M2 자막 생성(STT)" "type:feature,area:core" "영상 해시+모델+언어 키로 STT/번역 결과 재사용"
issue "Claude 번역 공급자" "M3 번역" "type:feature,area:translate" "Translator trait 구현, JSON {id,text} 응답, 누락 재시도"
issue "OpenAI 번역 공급자" "M3 번역" "type:feature,area:translate" "Translator trait 구현"
issue "Gemini 번역 공급자" "M3 번역" "type:feature,area:translate" "Translator trait 구현"
issue "API 키 OS 키체인 저장 + 설정 화면" "M3 번역" "type:feature,area:translate" "keyring 크레이트, 공급자/모델 선택 UI"
issue "스트리밍 번역 (앞부분부터 재생 가능)" "M3 번역" "type:feature,area:translate" "배치 순차 처리 결과를 Dart stream으로 전달"
issue "자막 목록 패널 + 클릭 이동" "M4 학습 UX" "type:feature,area:learning" ""
issue "문장 반복(A-B 루프) / 번역 가리기 모드" "M4 학습 UX" "type:feature,area:learning" ""
issue "단어 클릭 → 단어장 저장" "M4 학습 UX" "type:feature,area:learning" ""
issue "macOS 서명/공증 + DMG" "M5 배포" "type:chore,area:release" ""
issue "Windows 설치본(MSIX/Inno Setup)" "M5 배포" "type:chore,area:release" ""
issue "모바일 온디바이스 STT/오디오 추출 PoC" "M6 모바일" "type:feature,platform:mobile" "ffmpeg-kit 지원 종료 대응 방안 검증"
echo "완료: https://github.com/$REPO"
