#!/bin/zsh
# Builds build/Directory Organizer.app (Apple silicon; Apple's on-device model needs it).
# Works with just the Command Line Tools; full Xcode isn't required.
#   ./scripts/build-app.sh            release build
#   ./scripts/build-app.sh --open     build, then launch it
set -euo pipefail

cd "${0:A:h}/.."
APP="build/Directory Organizer.app"

swift build -c release --product DirectoryOrganizer
BIN="$(swift build -c release --show-bin-path)/DirectoryOrganizer"

# Quit a running copy so the new one replaces it.
pkill -x DirectoryOrganizer 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DirectoryOrganizer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # from scripts/make-icon.swift

# Ad-hoc signature: enough for macOS to run it and remember its permissions on this Mac.
codesign --force --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
