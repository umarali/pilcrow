#!/bin/sh
# HUMAN ONLY: create a self-signed code-signing identity in the login keychain.
# It is useful only on this Mac. Developer ID and notarization are a separate release path.
set -eu
cd "$(dirname "$0")/.."

if security find-certificate -c 'Pilcrow Local Signing' "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    echo 'A Pilcrow Local Signing certificate already exists in the login keychain.'
    echo 'Check its identity and trust in Keychain Access before building; no new certificate was created.'
    exit 0
fi

umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pilcrow-signing.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' HUP INT TERM
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -days 3650 -subj '/CN=Pilcrow Local Signing' \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=codeSigning'
P12_PASSWORD=$(/usr/bin/openssl rand -hex 16)
export P12_PASSWORD
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/identity.p12" -passout env:P12_PASSWORD
security import "$tmp/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$P12_PASSWORD" -x -T /usr/bin/codesign
unset P12_PASSWORD
# Print the SHA-1 as 40 hex digits so it can be pasted into PILCROW_SIGN_IDENTITY.
printf 'Certificate SHA-1: '
/usr/bin/openssl x509 -in "$tmp/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'
