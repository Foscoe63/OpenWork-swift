#!/bin/bash
# Create a self-signed code-signing certificate so this app has a *stable identity*.
#
# Why this exists: with no Developer ID on the machine, the app is ad-hoc signed, and macOS
# then identifies it by the binary's content hash. Every rebuild produces a new hash, which
# silently invalidates its TCC grants — Accessibility and Screen Recording stop working while
# the app stays ticked in System Settings. It reads "granted" and behaves "denied", and the
# perception tools (screenshot_window, accessibility_tree) are dead until you notice.
#
# Signing with a stable certificate makes TCC key on the certificate instead, so the grant
# survives rebuilds. This is NOT a substitute for a Developer ID: it does nothing for
# distribution or notarisation. It only makes local development sane.
#
# Run once. It will ask for your login password to trust the certificate.
set -euo pipefail

NAME="SwiftOpenWork Local Signing"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "'$NAME' already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no

[ dn ]
CN = $NAME

[ v3 ]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 7300 -nodes -config "$WORK/openssl.cnf"
openssl pkcs12 -export -out "$WORK/bundle.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout pass:swiftopenwork

security import "$WORK/bundle.p12" -k ~/Library/Keychains/login.keychain-db \
    -P swiftopenwork -T /usr/bin/codesign -T /usr/bin/security

echo "Approve the password prompt to trust the certificate for code signing…"
security add-trusted-cert -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "$WORK/cert.pem"

security find-identity -v -p codesigning

cat <<EOF

Done. Rebuild, then grant the app Accessibility and Screen Recording once:
  System Settings › Privacy & Security › Device Control and Data Access
  System Settings › Privacy & Security › Screen & System Audio Recording

Remove any existing OpenWork or SwiftOpenWork entry first — it points at the old ad-hoc binary — and add the
build you actually run. Those grants now survive rebuilds.
EOF
