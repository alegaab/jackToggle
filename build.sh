#!/bin/bash
# Builds JackToggle.app. Needs only the Command Line Tools — no Xcode.
set -euo pipefail

APP="JackToggle"
BUNDLE_ID="com.alegab.jacktoggle"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$ROOT/build/$APP.app"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

swiftc -swift-version 5 -O \
    -target arm64-apple-macos13.0 \
    -framework AppKit -framework IOKit -framework ServiceManagement \
    "$ROOT"/Sources/*.swift \
    -o "$APPDIR/Contents/MacOS/$APP"

cp "$ROOT/Info.plist" "$APPDIR/Contents/Info.plist"

# A stable identifier keeps the Input Monitoring grant across rebuilds where possible.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APPDIR" 2>&1 | sed 's/^/  codesign: /'

echo "Built $APPDIR"
