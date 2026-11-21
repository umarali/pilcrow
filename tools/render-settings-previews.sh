#!/bin/sh
# Compile just the Story view and its shortcut types. Never run Pilcrow itself.
set -eu
cd "$(dirname "$0")/.."
PREVIEW_SCRATCH="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_SCRATCH"' EXIT INT TERM
xcrun swiftc -parse-as-library \
  Sources/PilcrowApp/SettingsView.swift \
  Sources/PilcrowApp/ShortcutSettings.swift \
  Sources/PilcrowApp/HotKey.swift \
  tools/render-settings-previews.swift \
  -o "$PREVIEW_SCRATCH/render-settings"
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$PREVIEW_SCRATCH" CFFIXED_USER_HOME="$PREVIEW_SCRATCH" \
  "$PREVIEW_SCRATCH/render-settings" "${1:-/private/tmp/pilcrow-settings-preview}"
