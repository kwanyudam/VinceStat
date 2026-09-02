#!/bin/zsh
# VinceStat.app 번들 빌드
# 사용법: ./build.sh          → dist/VinceStat.app 생성
#         ./build.sh install  → /Applications 에 복사까지
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/VinceStat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp .build/release/VinceStat "$APP/Contents/MacOS/VinceStat"

# SPM 리소스 번들(펫 스프라이트)을 Contents/Resources 로. Bundle.module 이 Bundle.main.resourceURL
# 아래를 뒤지므로 여기 있어야 찾는다. 없으면 펫이 조용히 안 뜬다.
BUNDLE=.build/release/VinceStat_VinceStat.bundle
if [[ -d "$BUNDLE" ]]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
else
  echo "⚠️  $BUNDLE 이 없습니다 — 펫 스프라이트가 빠진 채로 빌드됩니다."
fi

# 고정 identity가 있으면 그것으로, 없으면 ad-hoc 서명
# (ad-hoc은 빌드마다 서명이 바뀌어 Keychain "항상 허용"이 유지되지 않음)
CERT_NAME="VinceStat Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  codesign --force --sign "$CERT_NAME" "$APP"
else
  echo "⚠️  '$CERT_NAME' 인증서가 없어 ad-hoc 서명합니다."
  echo "   재빌드마다 Keychain 팝업이 다시 뜨지 않게 하려면: ./setup-signing.sh (최초 1회)"
  codesign --force --sign - "$APP"
fi

echo "빌드 완료: $APP"

if [[ "${1:-}" == "install" ]]; then
  rm -rf /Applications/VinceStat.app
  cp -R "$APP" /Applications/VinceStat.app
  echo "/Applications/VinceStat.app 설치 완료"
fi
