#!/bin/zsh
# 编译菜单栏 App：dist/PatrolBar.app
# 只依赖系统 swiftc / SwiftUI / AppKit，无第三方库。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$ROOT/../.." && pwd)"
APP="$PROJECT/dist/PatrolBar.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

swiftc \
  -O \
  -swift-version 5 \
  -parse-as-library \
  -target "${ARCH}-apple-macosx14.0" \
  -framework SwiftUI \
  -framework AppKit \
  "$ROOT/PatrolBar/"*.swift \
  -o "$APP/Contents/MacOS/PatrolBar"

chmod +x "$APP/Contents/MacOS/PatrolBar"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
