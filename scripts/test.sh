#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed, the default
# build system intermittently fails to find the Swift Testing macro plugin
# ("plugin for module 'TestingMacros' not found"), so point at it explicitly.
# `swift test` compiles MLX (the first build takes several minutes). The tests fake the
# models, so they need neither the GPU nor the 5 GB of models; real-model checks are
# `organize model-check` and, later, the evaluation.
set -euo pipefail

cd "${0:A:h}/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"

if [[ -d "$PLUGINS" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
