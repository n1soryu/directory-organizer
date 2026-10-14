#!/bin/zsh
# Builds the app and zips it for a GitHub release:
#   build/Directory-Organizer-<version>.zip
set -euo pipefail

cd "${0:A:h}/.."
./scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/Directory-Organizer-$VERSION.zip"

rm -f "$ZIP"
# ditto keeps the bundle's signature and metadata intact, unlike plain zip.
ditto -c -k --keepParent "build/Directory Organizer.app" "$ZIP"

echo "Packaged $ZIP"
shasum -a 256 "$ZIP"
