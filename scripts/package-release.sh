#!/bin/zsh
# Builds the app and zips it for a GitHub release:
#   build/Directory-Organizer-<version>.zip
set -euo pipefail

cd "${0:A:h}/.."
./scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/Directory-Organizer-$VERSION.zip"

# The (ad-hoc) signature must be intact, or macOS refuses to open the app.
# --deep also checks the bundles inside, including MLX's shaders.
codesign --verify --deep --strict "build/Directory Organizer.app"
if [[ ! -f "build/Directory Organizer.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
  echo "error: the app is missing MLX's shaders (default.metallib)" >&2
  exit 1
fi

rm -f "$ZIP"
# ditto keeps the bundle's signature and metadata intact, unlike plain zip.
ditto -c -k --keepParent "build/Directory Organizer.app" "$ZIP"

echo "Packaged $ZIP"
shasum -a 256 "$ZIP"
