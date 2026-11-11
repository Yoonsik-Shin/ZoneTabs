#!/bin/bash
# 릴리스 빌드에 쓸 고정 서명 인증서를 만들어 GitHub 저장소 비밀값으로 등록한다. Mac에서 한 번만 실행한다.
#
# 인증서가 없으면 빌드마다 서명이 달라져서, 업데이트할 때마다 손쉬운 사용 권한을 다시 허용해야 한다.
# 같은 인증서로 계속 서명하면 macOS가 같은 앱으로 인식해 권한이 유지된다.
# 자체 서명 인증서라 Apple의 "확인되지 않은 개발자" 경고까지 없애 주지는 않는다.
#
# 다시 실행하면 새 인증서로 바뀌므로 권한을 한 번 더 허용해야 한다.
set -euo pipefail

REPO="${1:-Yoonsik-Shin/ZoneTabs}"

if ! command -v gh >/dev/null; then
    echo "GitHub CLI가 필요합니다: brew install gh && gh auth login" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ZoneTabs Self-Signed
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

# macOS 기본 openssl을 쓴다. 다른 버전이 만든 p12는 키체인이 읽지 못할 수 있다.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.conf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "ZoneTabs Self-Signed" -out "$TMP/cert.p12" -passout "pass:$PASS"

base64 -i "$TMP/cert.p12" | gh secret set SIGNING_CERT_P12 --repo "$REPO"
printf '%s' "$PASS" | gh secret set SIGNING_CERT_PASSWORD --repo "$REPO"

echo "등록 완료. 다음 릴리스부터 고정 인증서로 서명됩니다."
