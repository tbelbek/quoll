#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/macos"

# QUOLL_UNIVERSAL=1 builds arm64 + x86_64 (release builds); default is the host arch.
ARCHS=()
if [ "${QUOLL_UNIVERSAL:-0}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product QuollApp
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product quoll
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

APP="${QUOLL_APP:-$ROOT/.build/Quoll.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/QuollApp" "$APP/Contents/MacOS/Quoll"
# The CLI ships inside the bundle. Not as MacOS/quoll: APFS is case-insensitive by
# default, so that name would overwrite the app's own MacOS/Quoll executable.
cp "$BIN_DIR/quoll" "$APP/Contents/MacOS/quoll-cli"
chmod +x "$APP/Contents/MacOS/Quoll" "$APP/Contents/MacOS/quoll-cli"
cp "$ROOT/resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # resources/make-icon.sh

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Quoll</string>
    <key>CFBundleDisplayName</key>
    <string>Quoll</string>
    <key>CFBundleIdentifier</key>
    <string>com.quoll.search</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>Quoll</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>Search in Quoll</string></dict>
            <key>NSMessage</key>
            <string>searchInQuoll</string>
            <key>NSPortName</key>
            <string>Quoll</string>
            <key>NSRequiredContext</key>
            <dict/>
            <key>NSSendFileTypes</key>
            <array><string>public.folder</string><string>public.item</string></array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.quoll.search</string>
            <key>CFBundleURLSchemes</key>
            <array><string>quoll</string></array>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
PLIST

# A stable identity keeps privacy grants (Full Disk Access) across rebuilds; an
# ad-hoc signature changes with every build and macOS forgets the grant.
# A Developer ID identity (release.sh) also gets the hardened runtime + timestamp,
# which notarization requires.
IDENTITY="${QUOLL_SIGNING_IDENTITY:-Quoll Local Signing}"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    EXTRA=()
    case "$IDENTITY" in "Developer ID Application"*) EXTRA=(--options runtime --timestamp) ;; esac
    codesign --force ${EXTRA[@]+"${EXTRA[@]}"} --sign "$IDENTITY" --identifier com.quoll.search "$APP/Contents/MacOS/quoll-cli"
    codesign --force ${EXTRA[@]+"${EXTRA[@]}"} --sign "$IDENTITY" --identifier com.quoll.search "$APP"
else
    echo "note: no '$IDENTITY' identity; signing ad hoc (privacy grants reset on rebuild)"
    codesign --force --sign - "$APP/Contents/MacOS/quoll-cli" >/dev/null 2>&1 || true
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "built $APP"
