#!/bin/zsh
# Builds build/Directory Organizer.app and the matching CLI, build/cli/organize (Apple silicon).
# Uses xcodebuild, not `swift build`: only xcodebuild compiles MLX's GPU shaders
# (mlx-swift_Cmlx.bundle/…/default.metallib), and without them the models can't run.
# Needs full Xcode with the Metal toolchain.
#   ./scripts/build-app.sh            release build
#   ./scripts/build-app.sh --open     build, then launch it
set -euo pipefail

cd "${0:A:h}/.."
APP="build/Directory Organizer.app"
CLI="build/cli"
DERIVED="build/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"

for scheme in DirectoryOrganizer organize; do
  xcodebuild -quiet -scheme "$scheme" -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" build
done

# The packages' resource bundles: MLX's shaders, plus swift-crypto's and swift-transformers' data.
BUNDLES=("$PRODUCTS"/*.bundle)
if [[ ! -f "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
  echo "error: MLX's default.metallib wasn't built (is the Metal toolchain installed?)" >&2
  exit 1
fi

# Quit a running copy so the new one replaces it.
pkill -x DirectoryOrganizer 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/DirectoryOrganizer" "$APP/Contents/MacOS/DirectoryOrganizer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # from scripts/make-icon.swift
# In an app, the bundles are found in Contents/Resources.
for bundle in $BUNDLES; do ditto "$bundle" "$APP/Contents/Resources/${bundle:t}"; done

# Ad-hoc signature: enough for macOS to run it and remember its permissions on this Mac.
codesign --force --sign - "$APP"

# The CLI finds the bundles next to its executable.
rm -rf "$CLI"
mkdir -p "$CLI"
cp "$PRODUCTS/organize" "$CLI/organize"
for bundle in $BUNDLES; do ditto "$bundle" "$CLI/${bundle:t}"; done
codesign --force --sign - "$CLI/organize"

echo "Built $APP and $CLI/organize"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
