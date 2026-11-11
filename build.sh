#!/bin/bash
# ZoneTabs.app 번들을 build/ 아래에 만든다.
set -euo pipefail
cd "$(dirname "$0")"

# 실행 중인 이전 버전을 먼저 끈다. 켜 둔 채로 교체하거나 권한을 초기화하면 입력이 멈출 수 있다.
pkill -x ZoneTabs 2>/dev/null || true

# UNIVERSAL=1 이면 Apple Silicon과 Intel 양쪽에서 도는 바이너리를 만든다(배포용, Xcode 필요).
FLAGS=(-c release)
if [ -n "${UNIVERSAL:-}" ]; then
    FLAGS+=(--arch arm64 --arch x86_64)
fi

swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/ZoneTabs"

APP="build/ZoneTabs.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ZoneTabs"
cp Info.plist "$APP/Contents/Info.plist"
# SIGN_IDENTITY가 있으면 그 인증서로, 없으면 임시(ad-hoc) 서명을 한다.
# 고정 인증서로 서명한 빌드는 업데이트해도 손쉬운 사용 권한이 유지되므로, 앱이 알 수 있게 표시해 둔다.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :ZTStableSignature bool true" "$APP/Contents/Info.plist"
    codesign --force --sign "$SIGN_IDENTITY" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
else
    codesign --force --sign - "$APP"
fi

# 다시 빌드하면 서명이 바뀌어 예전 권한이 맞지 않게 된다. 깨끗이 지우고 새로 허용받는다.
tccutil reset Accessibility dev.zonetabs.app >/dev/null 2>&1 || true

echo "완료: $APP"
echo "권한이 초기화되었습니다. 실행 후 손쉬운 사용 권한을 다시 허용하세요."
echo "실행: open $APP"
