#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$PROJECT_ROOT/dist}"
mkdir -p "$DESTINATION" "$PROJECT_ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
cd "$PROJECT_ROOT"
swift build -c release --scratch-path "$PROJECT_ROOT/.build"
BIN_DIR="$(swift build -c release --scratch-path "$PROJECT_ROOT/.build" --show-bin-path)"
APP="$DESTINATION/WiFi ADB.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WiFiADB" "$APP/Contents/MacOS/WiFiADB"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WiFi ADB</string>
  <key>CFBundleDisplayName</key><string>WiFi ADB</string>
  <key>CFBundleExecutable</key><string>WiFiADB</string>
  <key>CFBundleIdentifier</key><string>com.lgj.wifiadb</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleShortVersionString</key><string>1.0.3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>发现同一局域网中的 Android 无线调试设备，并连接你选择的手机。</string>
  <key>NSBonjourServices</key><array><string>_adb-tls-connect._tcp</string><string>_adb-tls-pairing._tcp</string><string>_adb._tcp</string></array>
</dict></plist>
PLIST
swift "$PROJECT_ROOT/Scripts/make-icon.swift" "$PROJECT_ROOT/.build/AppIcon.iconset"
python3 "$PROJECT_ROOT/Scripts/make-icns.py" "$PROJECT_ROOT/.build/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
