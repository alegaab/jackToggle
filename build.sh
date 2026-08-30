#!/bin/bash
# Builds JackToggle.app. Needs only the Command Line Tools — no Xcode.
#   ./build.sh            build into ./build
#   ./build.sh --install  build, then replace /Applications/JackToggle.app and relaunch
set -euo pipefail

APP="JackToggle"
BUNDLE_ID="com.alegab.jacktoggle"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$ROOT/build/$APP.app"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

# --- app icon -------------------------------------------------------------
# The generator shares PlugIcon.swift with the app, so the Finder icon and the
# menu bar glyph are drawn from the same geometry.
ICONSET="$ROOT/build/$APP.iconset"
rm -rf "$ICONSET"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
    "$ROOT/Sources/PlugIcon.swift" "$ROOT/Tools/GenerateIcon.swift" \
    -o "$ROOT/build/generate-icon"
"$ROOT/build/generate-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APPDIR/Contents/Resources/$APP.icns"
rm -rf "$ICONSET" "$ROOT/build/generate-icon"

# --- app ------------------------------------------------------------------
swiftc -swift-version 5 -O \
    -target arm64-apple-macos13.0 \
    -framework AppKit -framework IOKit -framework CoreAudio -framework ServiceManagement \
    "$ROOT"/Sources/*.swift \
    -o "$APPDIR/Contents/MacOS/$APP"

cp "$ROOT/Info.plist" "$APPDIR/Contents/Info.plist"

codesign --force --sign - --identifier "$BUNDLE_ID" "$APPDIR" 2>&1 | sed 's/^/  codesign: /'
echo "Built $APPDIR"

# --- install --------------------------------------------------------------
if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP.app"
    WAS_RUNNING=$(pgrep -x "$APP" >/dev/null && echo yes || echo no)
    pkill -x "$APP" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APPDIR" "$DEST"
    echo "Installed $DEST"
    [[ "$WAS_RUNNING" == "yes" ]] && open "$DEST" && echo "Relaunched"
    echo
    echo "NOTE: a rebuilt binary has a new signature, so macOS may have dropped the"
    echo "      Input Monitoring grant. If toggling fails, remove JackToggle from"
    echo "      Privacy & Security > Input Monitoring with - and add it again."
fi
