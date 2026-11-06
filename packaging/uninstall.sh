#!/bin/bash
set -euo pipefail

LABEL="local.llm.litellm-stats"
BUNDLE_ID="com.github.huangxiaohua0313.LiteLLmStats"
UID_N="$(id -u)"

launchctl bootout "gui/${UID_N}/${LABEL}" 2>/dev/null || true

sudo rm -rf "/Applications/LiteLLmStats.app"
sudo rm -f "/Library/LaunchAgents/${LABEL}.plist"
sudo pkgutil --forget "$BUNDLE_ID" 2>/dev/null || true

rm -rf "$HOME/.litellmStats"
rm -rf "$HOME/.litellm/menubar"

echo "LiteLLmStats uninstalled."
