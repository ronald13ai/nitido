#!/bin/zsh
# Builds Nítido in release mode, assembles build/Nítido.app and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
# The version the bundle says and the zip is named after; the build number goes up with it.
VERSION=0.2
BUILD=2
# The identity first, so a Mac without one is told how to make one and no unsigned app is left behind (macOS keeps a
# Screen Recording grant only for a signed bundle). awk reads to the end: quitting at the first match could leave
# `security` writing into a closed pipe, which pipefail turns into a silent exit.
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/ && !id { id = $2 } END { print id }')
if [[ -z "$ID" ]]; then
  echo "bundle.sh: no Apple Development signing identity in the keychain. In Xcode, Settings, Accounts, Manage Certificates, add one (a free Apple ID works), then run this again." >&2
  exit 1
fi
# The whole compiler output goes to build/build.log; on a failure it is shown in full, so the error itself is on screen
# rather than only the count of errors on the last line.
mkdir -p build
if ! swift build -c release --product nitido > build/build.log 2>&1; then
  cat build/build.log >&2
  echo "bundle.sh: the release build failed (the full output is in build/build.log)." >&2
  exit 1
fi
tail -1 build/build.log
APP="build/Nítido.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/nitido "$APP/Contents/MacOS/nitido"
cp -R .build/release/nitido_NitidoUI.bundle "$APP/Contents/Resources/"
# The icon (scripts/make-icon.swift): Icon Composer's AppIcon.icon, compiled into the asset catalog, is the one macOS
# shows from macOS 11 on, and so on every system Nítido runs on: macOS 26 lays the N on its own glass, and actool
# flattens the one 1024 px layer for macOS 15 at every size (the iconset's stroked 16 and 32 px do not reach it: an app
# icon set passed to actool beside the .icon changes nothing in the catalog, measured with Xcode 26). actool writes its
# own AppIcon.icns from the .icon too; make-icon's goes in only when there is no .icon to compile.
ICON_NAME=""
if [ -d build/AppIcon.icon ]; then
  # Absolute paths: given relative ones, actool reports the file missing and still exits 0, so the catalog is checked too.
  if ! xcrun actool "$PWD/build/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
      --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon-partial.plist" \
      > build/actool.log 2>&1 || [ ! -f "$APP/Contents/Resources/Assets.car" ]; then
    cat build/actool.log >&2
    echo "bundle.sh: actool could not compile build/AppIcon.icon (the full output is in build/actool.log)." >&2
    exit 1
  fi
  ICON_NAME="  <key>CFBundleIconName</key><string>AppIcon</string>"
fi
if [ -z "$ICON_NAME" ] && [ -f build/AppIcon.icns ]; then cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nítido</string>
  <key>CFBundleDisplayName</key><string>Nítido</string>
  <key>CFBundleIdentifier</key><string>ai.ronar.nitido</string>
  <key>CFBundleExecutable</key><string>nitido</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
${ICON_NAME}
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
# The archive to attach to the GitHub release (the README's "From the zip"): ditto keeps the signature intact.
ZIP="build/Nitido-${VERSION}-macOS15.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "built $ZIP"
