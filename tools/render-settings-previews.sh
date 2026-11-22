#!/bin/sh
# Build an offscreen renderer with the real Settings and export code. Never run Pilcrow itself.
set -eu
cd "$(dirname "$0")/.."
PREVIEW_SCRATCH="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_SCRATCH"' EXIT INT TERM
PREVIEW_OUTPUT="${1:-/private/tmp/pilcrow-settings-preview}"
xcrun swift build --target PilcrowCore
CORE_BUILD="$(xcrun swift build --show-bin-path)"
set --
for source in Sources/PilcrowApp/*.swift; do
  [ "$source" = Sources/PilcrowApp/main.swift ] || set -- "$@" "$source"
done
xcrun swiftc -parse-as-library -I "$CORE_BUILD/Modules" \
  "$@" tools/render-settings-previews.swift "$CORE_BUILD"/PilcrowCore.build/*.swift.o \
  -o "$PREVIEW_SCRATCH/render-settings"
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$PREVIEW_SCRATCH" CFFIXED_USER_HOME="$PREVIEW_SCRATCH" \
  "$PREVIEW_SCRATCH/render-settings" "$PREVIEW_OUTPUT"
