#!/bin/bash
# Creates the local self-signed code-signing identity that build.sh needs,
# without going through the Certificate Assistant GUI (which often fails with
# "The specified item could not be found in the keychain" on recent macOS).
#
# Usage:
#   ./scripts/create-signing-cert.sh                 # creates "SRM Autoconnect Dev"
#   SIGN_IDENTITY="My Name" ./scripts/create-signing-cert.sh
#
# Afterwards verify with: security find-identity -v -p codesigning
set -e

CERT_NAME="${SIGN_IDENTITY:-SRM Autoconnect Dev}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
[ -f "$LOGIN_KEYCHAIN" ] || LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain"

if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
  echo "Identity \"$CERT_NAME\" already exists — nothing to do."
  security find-identity -v -p codesigning | grep -F "$CERT_NAME"
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found, which is unusual for macOS. Update Command Line Tools and retry." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extension profile: a self-signed root allowed to code-sign, mirroring what
# Keychain Access > Certificate Assistant > "Code Signing" would create.
# A config file (instead of -addext) works on both LibreSSL and OpenSSL.
cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $CERT_NAME
[v3_req]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/openssl.cnf" -extensions v3_req >/dev/null 2>&1

# Random password for the transient .p12; the key ends up passwordless in the keychain.
# NOTE: OpenSSL 3 defaults to AES-256-CBC for .p12 files, which macOS's
# `security import` cannot read ("MAC verification failed ... (wrong password?)"
# even though the password is correct). Force the classic 3DES format instead:
# `-legacy` on OpenSSL 3, explicit PBEs elsewhere (incl. macOS LibreSSL).
P12_PASS="$(openssl rand -hex 16)"
P12_OPTS="-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES"
if openssl pkcs12 -help 2>&1 | grep -q "\-legacy"; then
  P12_OPTS="-legacy"
fi
openssl pkcs12 -export -name "$CERT_NAME" $P12_OPTS \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$P12_PASS"

# -T whitelists codesign/security so the first build doesn't spam access prompts.
security import "$TMP/identity.p12" -k "$LOGIN_KEYCHAIN" \
  -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security

# Trust it for code signing (user domain — no sudo needed).
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$LOGIN_KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 || true

echo ""
if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
  echo "Created identity \"$CERT_NAME\"."
  security find-identity -v -p codesigning | grep -F "$CERT_NAME"
  echo ""
  echo "If codesign still prompts for keychain access, choose 'Always Allow' once."
  echo "Then build with: ./build.sh"
else
  echo "Import ran but \"$CERT_NAME\" is still not listed. Try:" >&2
  echo "  security find-identity -v -p codesigning" >&2
  echo "and check Keychain Access > login for a stuck entry." >&2
  exit 1
fi
