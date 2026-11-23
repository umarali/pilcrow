#!/bin/sh
# Build and run an offscreen tool with the real Pilcrow exporter.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
DEMO_SCRATCH="$(mktemp -d "$PWD/.build/readme-demo.XXXXXX")"
trap 'rm -rf "$DEMO_SCRATCH"' EXIT INT TERM
DEMO_OUTPUT="${1:-$PWD/docs/images}"

xcrun swift build --scratch-path "$DEMO_SCRATCH/build" --target PilcrowCore
CORE_BUILD="$(xcrun swift build --scratch-path "$DEMO_SCRATCH/build" --show-bin-path)"
set --
for source in Sources/PilcrowApp/*.swift; do
  [ "$source" = Sources/PilcrowApp/main.swift ] || set -- "$@" "$source"
done
xcrun swiftc -parse-as-library -I "$CORE_BUILD/Modules" \
  "$@" tools/render-readme-demo.swift "$CORE_BUILD"/PilcrowCore.build/*.swift.o \
  -o "$DEMO_SCRATCH/render-readme-demo"

env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$DEMO_SCRATCH" \
  CFFIXED_USER_HOME="$DEMO_SCRATCH" TMPDIR="$DEMO_SCRATCH" \
  "$DEMO_SCRATCH/render-readme-demo" "$DEMO_OUTPUT" "$DEMO_SCRATCH/export"
