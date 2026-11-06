#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/dist/LiteLLmStats.app"
BIN="$APP/Contents/MacOS/LiteLLmStats"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  "$DIR/Sources/main.swift" \
  -o "$BIN" \
  -framework AppKit

cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built: $APP"
