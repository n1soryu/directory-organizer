#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed, the default
# build system intermittently fails to find the Swift Testing macro plugin
# ("plugin for module 'TestingMacros' not found"), so point at it explicitly.
# `swift test` compiles MLX (the first build takes several minutes) but can't run it:
# it builds no GPU shaders. The tests fake the models; real-model checks are
# `build/cli/organize model-check` after ./scripts/build-app.sh.
set -euo pipefail

cd "${0:A:h}/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"

if [[ -d "$PLUGINS" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
