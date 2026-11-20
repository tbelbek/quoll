#!/bin/bash
# Creates a self-signed code-signing identity ("Quoll Local Signing") in the login
# keychain. Builds signed with it keep macOS privacy grants (Full Disk Access)
# across rebuilds; ad-hoc builds lose them every time. Local use only: it does not
# make a build trusted on other Macs (that needs an Apple Developer ID).
set -euo pipefail
NAME="${1:-Quoll Local Signing}"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "identity '$NAME' already exists"
    exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
    -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" \
    -passout "pass:$PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "macOS will ask for your password to trust the certificate for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
security find-identity -v -p codesigning | grep "\"$NAME\""
