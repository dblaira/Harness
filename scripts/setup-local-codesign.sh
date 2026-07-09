#!/bin/sh
# One-time setup: creates the "Harness Local Dev" self-signed
# certificate that project.yml's macOS CODE_SIGN_IDENTITY points at.
#
# Why this exists: ad-hoc signing (the default when CODE_SIGNING_ALLOWED
# is off) ties the app's Keychain access grants to the exact binary
# hash, which changes on every rebuild -- macOS treats each new build
# as a different app and re-prompts for your login password to access
# anything Harness previously stored in Keychain (e.g. a saved API
# key). A real signing certificate's designated requirement keys on
# the certificate itself, not the binary, so the same certificate
# signing different builds looks like the same app every time and the
# grant persists across rebuilds.
#
# This is a self-signed, local-only certificate -- no Apple Developer
# account involved, nothing leaves this Mac. Safe to re-run; it's a
# no-op if "Harness Local Dev" already exists in the login keychain.
#
# Run once per machine: sh scripts/setup-local-codesign.sh

set -e

CERT_NAME="Harness Local Dev"

if security find-certificate -c "$CERT_NAME" -a login.keychain-db >/dev/null 2>&1; then
    echo "\"$CERT_NAME\" already exists in the login keychain -- nothing to do."
    exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/codesign.cfg" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $CERT_NAME

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
    -days 3650 -nodes -config "$WORKDIR/codesign.cfg"

# macOS's `security import` can't read modern OpenSSL 3.x's default
# AES-256/SHA-256 PKCS12 encryption ("MAC verification failed" even
# with the right password) -- use the legacy RC2/SHA1 scheme it
# understands.
openssl pkcs12 -export -legacy \
    -out "$WORKDIR/cert.p12" \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
    -passout pass:temporary

# -T /usr/bin/codesign grants the codesign tool permission to use the
# private key without prompting on every build.
security import "$WORKDIR/cert.p12" -k ~/Library/Keychains/login.keychain-db -P temporary -T /usr/bin/codesign -A

echo "\"$CERT_NAME\" installed. xcodegen generate && xcodebuild ... build will now use it."
