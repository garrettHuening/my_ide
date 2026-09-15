#!/bin/bash
# Build the spike and assemble build/Spike.app with an embedded LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
swift build
BIN=.build/debug
APP=build/Spike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/SpikeApp" "$BIN/spike-agentd" "$BIN/spike-client" "$APP/Contents/MacOS/"
cp Support/dev.cch.spike.agentd.plist "$APP/Contents/Library/LaunchAgents/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SpikeApp</string>
  <key>CFBundleIdentifier</key><string>dev.cch.spike.app</string>
  <key>CFBundleName</key><string>CCH Spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.cch.spike.agentd "$APP/Contents/MacOS/spike-agentd"
codesign --force --sign - --identifier dev.cch.spike.client "$APP/Contents/MacOS/spike-client"
codesign --force --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "built $APP"
