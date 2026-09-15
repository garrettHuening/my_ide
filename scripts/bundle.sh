#!/bin/bash
# Build Claude Code Hub and assemble a signed .app bundle in build/.
# Usage: scripts/bundle.sh [--run]     CONFIG=release scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG"
APP="build/ClaudeCodeHub.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Replace binaries with new files (not in place) so running Hub/claude/cch-mcp processes keep their old image.
for exe in ClaudeCodeHub cch-mcp; do
  rm -f "$APP/Contents/MacOS/$exe"
  cp "$BIN/$exe" "$APP/Contents/MacOS/$exe"
done
rm -rf "$APP/Contents/Resources/plugins"
cp -R Resources/plugins "$APP/Contents/Resources/plugins"

codesign --force --sign - --identifier dev.cch.mcp "$APP/Contents/MacOS/cch-mcp"
codesign --force --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Built $APP ($CONFIG)"

if [[ "${1:-}" == "--run" ]]; then
  pkill -f "ClaudeCodeHub.app/Contents/MacOS/ClaudeCodeHub" || true
  sleep 1
  open "$APP"
fi
