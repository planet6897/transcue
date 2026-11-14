#!/usr/bin/env bash
# Transcue를 Linux(Debian·Ubuntu 계열)에서 빌드·실행하는 데 필요한 것을 설치한다.
#   - 빌드: clang, cmake, ninja, GTK 3, libmpv (Flutter Linux 데스크톱 + media_kit)
#   - 실행: ffmpeg, yt-dlp, whisper.cpp (whisper-cli, parakeet-cli)
# yt-dlp와 whisper.cpp는 ~/.local/bin에 둔다 (앱이 PATH와 함께 이 폴더를 찾아본다).
# 사용: bash scripts/setup-linux.sh
set -euo pipefail

# Windows 설치 스크립트(setup-windows.ps1)와 같은 버전
WHISPER_VERSION=v1.9.2
BIN="$HOME/.local/bin"

if ! command -v apt-get >/dev/null; then
  echo "apt-get이 없습니다. 배포판의 패키지 관리자로 다음을 설치한 뒤 다시 실행하세요:" >&2
  echo "  clang cmake ninja pkg-config git curl python3, GTK 3·libmpv 개발 패키지, mpv, ffmpeg" >&2
  exit 1
fi

echo "패키지 설치 (sudo 암호를 물을 수 있습니다) ..."
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config git curl python3 \
  libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libmpv-dev mpv ffmpeg

mkdir -p "$BIN"

# 배포판 패키지의 yt-dlp는 오래돼 YouTube가 바뀌면 동작하지 않는다 → 공식 최신판
if [ -x "$BIN/yt-dlp" ]; then
  echo "yt-dlp가 이미 있습니다: $BIN/yt-dlp (갱신: yt-dlp -U)"
else
  echo "yt-dlp 설치 ..."
  curl -fL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$BIN/yt-dlp"
  chmod +x "$BIN/yt-dlp"
fi

if [ -x "$BIN/whisper-cli" ]; then
  echo "whisper.cpp가 이미 있습니다: $BIN/whisper-cli"
else
  echo "whisper.cpp $WHISPER_VERSION 빌드 (몇 분 걸립니다) ..."
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  git clone --depth 1 --branch "$WHISPER_VERSION" \
    https://github.com/ggml-org/whisper.cpp "$tmp/whisper.cpp"
  # 실행 파일만 옮겨 쓸 수 있게 라이브러리를 안에 넣어 빌드한다
  cmake -S "$tmp/whisper.cpp" -B "$tmp/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  cmake --build "$tmp/build"
  install -m 755 "$tmp/build/bin/whisper-cli" "$BIN/whisper-cli"
  if [ -f "$tmp/build/bin/parakeet-cli" ]; then
    install -m 755 "$tmp/build/bin/parakeet-cli" "$BIN/parakeet-cli"
  else
    echo "parakeet-cli가 빌드되지 않았습니다. 영어 음성도 whisper로 인식합니다." >&2
  fi
fi

echo "끝. Transcue가 실행 중이면 다시 시작하세요."
