#!/bin/zsh
# Builds MenuBarTodo.app from Sources/ using swiftc (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MenuBarTodo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/MenuBarTodo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MenuBarTodo</string>
  <key>CFBundleDisplayName</key><string>Menu Bar To-Do</string>
  <key>CFBundleIdentifier</key><string>com.local.menubartodo</string>
  <key>CFBundleExecutable</key><string>MenuBarTodo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
