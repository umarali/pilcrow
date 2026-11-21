#!/bin/sh
# Build and sign the bundle without launching it.
set -eu
cd "$(dirname "$0")/.."

configuration=release
case "$#:$*" in
    0:) ;;
    1:--debug) configuration=debug ;;
    *) echo "Usage: $0 [--debug]" >&2; exit 2 ;;
esac

# Require exactly one simple version declaration; do not silently ship a stale version.
version=$(sed -nE 's/^[[:space:]]*public static let version[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' Sources/PilcrowCore/PilcrowCore.swift)
case "$version" in
    ''|*'
'*) echo 'Could not find exactly one PilcrowCore.version (major.minor.patch).' >&2; exit 1 ;;
esac

xcrun swift build -c "$configuration"
bin_dir=$(xcrun swift build -c "$configuration" --show-bin-path)
bundle=build/Pilcrow.app
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/Pilcrow" "$bundle/Contents/MacOS/Pilcrow"
cp "$bin_dir/pilcrow-mcp" "$bundle/Contents/MacOS/pilcrow-mcp"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$bundle/Contents/Info.plist"

identity_output=$(security find-identity -v -p codesigning)
if [ -n "${PILCROW_SIGN_IDENTITY:-}" ]; then
    identity=$PILCROW_SIGN_IDENTITY
else
    local_matches=$(printf '%s\n' "$identity_output" | awk -F '"' '$2 == "Pilcrow Local Signing" { prefix = $1; sub(/^.*\) /, "", prefix); sub(/[[:space:]]+$/, "", prefix); print prefix }')
    match_count=$(printf '%s\n' "$local_matches" | awk 'NF { count++ } END { print count + 0 }')
    case "$match_count" in
        0) identity=- ;;
        1) identity=$local_matches ;;
        *) echo "Found $match_count valid identities named 'Pilcrow Local Signing'; remove duplicates or set PILCROW_SIGN_IDENTITY explicitly." >&2; exit 1 ;;
    esac
fi

certificate_name=$identity
if [ "${#identity}" -eq 40 ]; then
    case "$identity" in
        *[!0123456789abcdefABCDEF]*) ;;
        *)
            certificate_name=$(printf '%s\n' "$identity_output" | awk -F '"' -v wanted="$identity" '$2 != "" { prefix = $1; sub(/^.*\) /, "", prefix); sub(/[[:space:]]+$/, "", prefix); if (toupper(prefix) == toupper(wanted)) { print $2; exit } }')
            ;;
    esac
fi

timestamp_flag=--timestamp=none
case "${PILCROW_TIMESTAMP:-}" in
    1) timestamp_flag=--timestamp ;;
    *)
        case "$certificate_name" in
            'Developer ID Application:'*) timestamp_flag=--timestamp ;;
        esac
        ;;
esac

printf 'Signing identity: %s\n' "$identity"
if [ "$identity" = - ]; then
    echo 'WARNING: Ad-hoc signing is in use. macOS permissions may reset on every rebuild.' >&2
    echo 'For a stable local identity, see docs/building.md.' >&2
fi
codesign --force --sign "$identity" --identifier org.pilcrow.app.pilcrow-mcp --options runtime "$timestamp_flag" "$bundle/Contents/MacOS/pilcrow-mcp"
codesign --force --sign "$identity" --options runtime --entitlements Resources/Pilcrow.entitlements "$timestamp_flag" "$bundle"
codesign --verify --deep --strict "$bundle"
codesign -d -r- "$bundle"
printf 'Built %s\nTo launch manually: open %s\n' "$bundle" "$bundle"
