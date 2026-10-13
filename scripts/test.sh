#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed, the default
# build system intermittently fails to find the Swift Testing macro plugin
# ("plugin for module 'TestingMacros' not found"), so point at it explicitly.
set -euo pipefail

cd "${0:A:h}/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"

if [[ -d "$PLUGINS" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
