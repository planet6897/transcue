#!/usr/bin/env bash
# Transcue macOS 앱을 터미널에서 설치한다 (최신 GitHub Release의 universal 앱).
#
#   curl -fsSL https://raw.githubusercontent.com/planet6897/transcue/main/scripts/install-macos.sh | bash
#
# 앱에 Apple 개발자 서명·공증이 없어서 브라우저로 받은 zip은 macOS(Gatekeeper)가 열지 못하게 막는다.
# curl로 받은 파일에는 "인터넷에서 받음" 표시(quarantine)가 붙지 않아 그대로 열린다.
#
#   TRANSCUE_VERSION=0.10.0  특정 버전 설치 (기본: 최신)
#   TRANSCUE_DEST=폴더       설치할 폴더 (기본: /Applications, 쓸 수 없으면 ~/Applications)
set -euo pipefail

REPO=planet6897/transcue

if [ "$(uname -s)" != Darwin ]; then
  echo "macOS용 설치 스크립트입니다." >&2
  exit 1
fi

if [ -n "${TRANSCUE_VERSION:-}" ]; then
  tag="v${TRANSCUE_VERSION#v}"
else
  # releases/latest는 최신 태그 주소로 넘어간다 (…/releases/tag/vX.Y.Z)
  latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
  tag=${latest##*/}
fi
ver=${tag#v}
case "$ver" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "최신 버전을 알아내지 못했습니다 ($tag)." >&2; exit 1 ;;
esac

dest=${TRANSCUE_DEST:-/Applications}
if [ -z "${TRANSCUE_DEST:-}" ] && [ ! -w "$dest" ]; then
  dest="$HOME/Applications"
fi
mkdir -p "$dest"
app="$dest/Transcue.app"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

url="https://github.com/$REPO/releases/download/$tag/transcue-$ver-macos-universal.zip"
echo "Transcue $ver 내려받는 중 ..."
if ! curl -fL --progress-bar -o "$tmp/transcue.zip" "$url"; then
  echo "내려받지 못했습니다: $url" >&2
  echo "방금 나온 버전이면 macOS 앱이 아직 올라오지 않았을 수 있습니다 (배포 후 10분 안팎)." >&2
  exit 1
fi
ditto -x -k "$tmp/transcue.zip" "$tmp/out"
if [ ! -d "$tmp/out/Transcue.app" ]; then
  echo "받은 파일에 Transcue.app이 없습니다." >&2
  exit 1
fi

# 설치된 앱이 실행 중이면 끝내고 바꾼다
pkill -f "$app/Contents/MacOS/" 2>/dev/null || true
rm -rf "$app"
ditto "$tmp/out/Transcue.app" "$app"
# 예전에 브라우저로 받아 둔 것을 덮어쓴 경우 등: 남아 있을 수 있는 표시를 지운다
xattr -cr "$app" 2>/dev/null || true

echo "설치했습니다: $app"
echo "실행: open \"$app\""
echo "음성 인식·YouTube에는 외부 도구가 필요합니다: brew install ffmpeg whisper-cpp yt-dlp"
