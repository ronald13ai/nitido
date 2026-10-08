#!/bin/zsh
# Builds Nítido in release mode, assembles build/Nítido.app and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
# The identity first, so a Mac without one is told how to make one and no unsigned app is left behind (macOS keeps a
# Screen Recording grant only for a signed bundle). awk reads to the end: quitting at the first match could leave
# `security` writing into a closed pipe, which pipefail turns into a silent exit.
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/ && !id { id = $2 } END { print id }')
if [[ -z "$ID" ]]; then
  echo "bundle.sh: no Apple Development signing identity in the keychain. In Xcode, Settings, Accounts, Manage Certificates, add one (a free Apple ID works), then run this again." >&2
  exit 1
fi
swift build -c release --product nitido 2>&1 | tail -1
APP="build/Nítido.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/nitido "$APP/Contents/MacOS/nitido"
cp -R .build/release/nitido_NitidoUI.bundle "$APP/Contents/Resources/"
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nítido</string>
  <key>CFBundleDisplayName</key><string>Nítido</string>
  <key>CFBundleIdentifier</key><string>ai.ronar.nitido</string>
  <key>CFBundleExecutable</key><string>nitido</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Nítido finds and talks to other Macs running Nítido on your local network.</string>
  <key>NSBonjourServices</key><array><string>_nitido._tcp</string></array>
  <key>NSHumanReadableCopyright</key><string>Ronald Rodríguez · RONAR AI · MIT License</string>
</dict></plist>
PLIST
codesign --force --deep --sign "$ID" "$APP"
codesign --verify --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority" | head -2
echo "built $APP"
