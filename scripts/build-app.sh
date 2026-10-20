#!/bin/bash
# Builds build/Reel.app (release, signed). Pass --dmg to also make build/Reel.dmg,
# --install to copy it to /Applications and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"

swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN="$(swift build -c release --show-bin-path 2>/dev/null)"
[ -x "$BIN/Reel" ] || BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP=build/Reel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Reel" "$APP/Contents/MacOS/Reel"
cp "$BIN/reelctl" "$APP/Contents/MacOS/reelctl"

if [ ! -f build/Reel.icns ] || [ scripts/make-icon.swift -nt build/Reel.icns ]; then
    rm -rf build/Reel.iconset
    swift scripts/make-icon.swift build/Reel.iconset
    iconutil -c icns build/Reel.iconset -o build/Reel.icns
fi
cp build/Reel.icns "$APP/Contents/Resources/Reel.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.reel</string>
    <key>CFBundleName</key><string>Reel</string>
    <key>CFBundleDisplayName</key><string>Reel</string>
    <key>CFBundleExecutable</key><string>Reel</string>
    <key>CFBundleIconFile</key><string>Reel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Anthony Radke</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>app.reel</string>
            <key>CFBundleURLSchemes</key><array><string>reel</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP/Contents/MacOS/reelctl"
    codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
else
    codesign --force -s - "$APP"
fi
echo "built $APP ($VERSION, $BUILD)"

for arg in "$@"; do
    case "$arg" in
    --dmg)
        rm -rf build/dmg build/Reel.dmg
        mkdir -p build/dmg
        cp -R "$APP" build/dmg/
        ln -s /Applications build/dmg/Applications
        hdiutil create -volname Reel -srcfolder build/dmg -ov -format UDZO build/Reel.dmg >/dev/null
        rm -rf build/dmg
        echo "built build/Reel.dmg"
        ;;
    --install)
        pkill -x Reel 2>/dev/null || true
        sleep 0.5
        rm -rf /Applications/Reel.app
        cp -R "$APP" /Applications/
        open /Applications/Reel.app
        echo "installed /Applications/Reel.app"
        ;;
    esac
done
