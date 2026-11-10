#!/bin/bash
# ZoneTabs를 빌드해서 /Applications 에 설치하고 실행한다. 업데이트할 때도 이 스크립트를 다시 실행하면 된다.
set -euo pipefail
cd "$(dirname "$0")"

bash build.sh

DEST="/Applications/ZoneTabs.app"
rm -rf "$DEST"
cp -R build/ZoneTabs.app "$DEST"
open "$DEST"

echo "설치 완료: $DEST"
echo "처음 실행이거나 업데이트한 경우, 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 ZoneTabs를 켜세요."
