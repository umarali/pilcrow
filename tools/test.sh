#!/bin/sh
# Run the unit tests with a throwaway HOME and a minimal environment (no inherited secrets).
# This is not a sandbox: code that looks up the home folder by user ID still finds the real one.
# Uses `xcrun swift` because a `swift` found first on PATH can be a stale toolchain.
set -eu
cd "$(dirname "$0")/.."
SCRATCH_HOME="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_HOME"' EXIT INT TERM
env -i \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$SCRATCH_HOME" \
  CFFIXED_USER_HOME="$SCRATCH_HOME" \
  DEVELOPER_DIR="$(xcode-select -p)" \
  xcrun swift test "$@"
