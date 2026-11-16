#!/bin/bash
# 최신 릴리스를 받아 /Applications 에 설치하고 실행한다.
# 터미널로 받으면 "인터넷에서 받음" 표시가 붙지 않아 Gatekeeper의 "열지 않음" 경고가 뜨지 않는다.
#
#   curl -fsSL https://raw.githubusercontent.com/Yoonsik-Shin/ZoneTabs/master/scripts/install-release.sh | bash
set -euo pipefail

URL="https://github.com/Yoonsik-Shin/ZoneTabs/releases/latest/download/ZoneTabs.dmg"
TMP="$(mktemp -d)"
MNT="$TMP/mount"
cleanup() {
    hdiutil detach "$MNT" -quiet 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "최신 버전을 받는 중…"
curl -fsSL -o "$TMP/ZoneTabs.dmg" "$URL"
mkdir -p "$MNT"
hdiutil attach "$TMP/ZoneTabs.dmg" -nobrowse -quiet -mountpoint "$MNT"

# 실행 중인 앱을 먼저 끈 뒤에 교체한다.
pkill -x ZoneTabs 2>/dev/null || true
sleep 1
rm -rf /Applications/ZoneTabs.app
ditto "$MNT/ZoneTabs.app" /Applications/ZoneTabs.app
xattr -dr com.apple.quarantine /Applications/ZoneTabs.app 2>/dev/null || true

open /Applications/ZoneTabs.app
echo "설치 완료. 손쉬운 사용 권한 요청이 뜨면 허용하세요."
echo "상태를 확인하려면: open /Applications/ZoneTabs.app (실행 중에 다시 열면 상태 창이 뜹니다)"
