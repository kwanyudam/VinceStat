#!/bin/zsh
# VinceStat 코드서명용 자체 인증서 생성/등록 (머신당 최초 1회)
#
# ad-hoc 서명은 빌드마다 서명이 달라져 macOS가 매번 다른 앱으로 취급하므로,
# Keychain "항상 허용"이 재빌드 후 유지되지 않는다. 고정 identity로 서명하면
# 서명 주체가 동일해 권한이 계속 유지된다.
#
# 사용법: ./setup-signing.sh
#   - 신뢰 등록 단계에서 macOS 암호 확인 창이 한 번 뜰 수 있다.
#   - 이후 ./build.sh 가 이 인증서를 자동으로 사용한다.
set -euo pipefail

CERT_NAME="VinceStat Signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "이미 '$CERT_NAME' 인증서가 있습니다. 바로 ./build.sh 하면 됩니다."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1) 코드서명 용도(EKU=codeSigning)의 10년짜리 자체 서명 인증서 생성
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$CERT_NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"

# 2) p12로 묶어 로그인 키체인에 임포트 (-T: codesign이 키에 접근할 때 묻지 않도록)
# OpenSSL 3의 기본 p12 암호화는 macOS security import가 못 읽으므로 -legacy 사용
# (LibreSSL에는 -legacy가 없지만 기본 포맷이 이미 호환됨)
legacy_flag=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
  legacy_flag=(-legacy)
fi
openssl pkcs12 -export "${legacy_flag[@]}" -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:vincestat
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
  -P vincestat -T /usr/bin/codesign

# 3) 코드서명 정책으로 신뢰 등록 (macOS 암호 확인 창이 뜰 수 있음)
security add-trusted-cert -p codeSign \
  -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo "'$CERT_NAME' 인증서 등록 완료. 이제 ./build.sh 로 빌드하면 고정 서명이 적용됩니다."
