#!/bin/sh
# Creates a self-signed code-signing certificate ("Kuronami Local Signing") in your login
# keychain, once, and points builds at it. Signed with one identity, Kuronami keeps the folder
# access you allow (Desktop, Documents, …) across rebuilds and reinstalls.
set -eu
cd "$(dirname "$0")/.."
NAME="Kuronami Local Signing"
if ! security find-identity -p codesigning | grep -q "\"$NAME\""; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  /usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
    -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false" 2>/dev/null
  PASS=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -passout "pass:$PASS"
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
fi
printf 'CODE_SIGN_IDENTITY = %s\n' "$NAME" > Signing.local.xcconfig
echo "Builds now sign as \"$NAME\". Allow folder access once more after the next build; it sticks from then on."
