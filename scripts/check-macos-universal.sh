#!/usr/bin/env bash
# macOS 앱 안의 모든 실행 파일·라이브러리에 Intel(x86_64)과 Apple Silicon(arm64)이 둘 다 있는지.
# 사용: scripts/check-macos-universal.sh build/macos/Build/Products/Release/Transcue.app
set -uo pipefail
app="${1:?앱 경로}"
[ -d "$app" ] || { echo "::error::앱이 없습니다: $app"; exit 1; }

bad=0
n=0
while IFS= read -r f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  n=$((n + 1))
  archs=$(lipo -archs "$f" 2>/dev/null || echo '?')
  for want in x86_64 arm64; do
    case " $archs " in
      *" $want "*) ;;
      *) echo "::error::$want 없음: ${f#"$app"/} ($archs)"; bad=1 ;;
    esac
  done
done < <(find "$app" -type f)

if [ "$n" -eq 0 ]; then
  echo "::error::실행 파일을 하나도 찾지 못했습니다: $app"
  exit 1
fi
echo "실행 파일·라이브러리 ${n}개: $([ $bad -eq 0 ] && echo '모두 x86_64 + arm64' || echo '빠진 것 있음')"
exit $bad
