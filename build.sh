#!/bin/zsh
# VinceStat.app 번들 빌드
# 사용법: ./build.sh          → dist/VinceStat.app 생성
#         ./build.sh install  → /Applications 에 복사까지
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/VinceStat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp .build/release/VinceStat "$APP/Contents/MacOS/VinceStat"
codesign --force --sign - "$APP"

echo "빌드 완료: $APP"

if [[ "${1:-}" == "install" ]]; then
  rm -rf /Applications/VinceStat.app
  cp -R "$APP" /Applications/VinceStat.app
  echo "/Applications/VinceStat.app 설치 완료"
fi
