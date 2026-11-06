#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="LiteLLmStats"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.github.huangxiaohua0313.LiteLLmStats"
LABEL="local.llm.litellm-stats"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/Resources/Info.plist")"

"$DIR/build.sh"

WORK="$(mktemp -d "/tmp/${APP_NAME}-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
mkdir -p "$ROOT/Applications" "$ROOT/Library/LaunchAgents"
/usr/bin/ditto --noextattr --noacl --noqtn \
    "$DIR/dist/${APP_BUNDLE}" "$ROOT/Applications/${APP_BUNDLE}"

cat > "$ROOT/Library/LaunchAgents/${LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/${APP_NAME}.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${APP_NAME}.err.log</string>
</dict>
</plist>
PLIST

# 去掉 macOS 自动附加的 provenance 等扩展属性，避免 payload 里出现 ._ 文件
xattr -cr "$ROOT"

# 禁用 bundle relocation，避免 Installer 把 app 安装到别处
COMPONENTS="$WORK/components.plist"
pkgbuild --analyze --root "$ROOT" "$COMPONENTS" >/dev/null
/usr/libexec/PlistBuddy \
    -c "Set :Applications/${APP_BUNDLE}:BundleIsRelocatable false" \
    -c "Set :Applications/${APP_BUNDLE}:BundleHasStrictIdentifier true" \
    -c "Set :Applications/${APP_BUNDLE}:BundleOverwriteAction upgrade" \
    "$COMPONENTS"

OUT="$DIR/dist/${APP_NAME}-${VERSION}.pkg"
pkgbuild \
    --root "$ROOT" \
    --component-plist "$COMPONENTS" \
    --scripts "$DIR/packaging/scripts" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location / \
    --ownership recommended \
    "$OUT"

echo "built: $OUT"
