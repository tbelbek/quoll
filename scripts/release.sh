#!/bin/bash
# Builds a universal (arm64 + x86_64) Quoll.app and zips it for a GitHub release.
#
# Signing, in order of preference:
#   1. QUOLL_SIGNING_IDENTITY="Developer ID Application: …" plus a notarytool
#      keychain profile in QUOLL_NOTARY_PROFILE → signed, notarized, stapled:
#      opens on any Mac without warnings.
#   2. Otherwise ad hoc: users clear the quarantine flag once (see README).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

export QUOLL_UNIVERSAL=1
export QUOLL_APP="$DIST/Quoll.app"   # never overwrite a locally signed .build/Quoll.app
if [ -z "${QUOLL_SIGNING_IDENTITY:-}" ]; then export QUOLL_SIGNING_IDENTITY="-none-"; fi
"$ROOT/scripts/build-app.sh"

ZIP="$DIST/Quoll-$VERSION-macos-universal.zip"
ditto -c -k --keepParent "$QUOLL_APP" "$ZIP"

if [ -n "${QUOLL_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$QUOLL_NOTARY_PROFILE" --wait
    xcrun stapler staple "$QUOLL_APP"
    rm "$ZIP"
    ditto -c -k --keepParent "$QUOLL_APP" "$ZIP"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
lipo -archs "$QUOLL_APP/Contents/MacOS/Quoll"
rm -rf "$QUOLL_APP"
echo "release: $ZIP"
