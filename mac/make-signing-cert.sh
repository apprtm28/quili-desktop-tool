#!/usr/bin/env bash
# Creates the self-signed code-signing certificate "Quili Dev" in your login keychain (one-time setup).
#
#   ./make-signing-cert.sh             create it and trust it for code signing
#   ./make-signing-cert.sh --export    also write QuiliDev.p12 + print the GitHub secrets to add
#
# Every build signed with the same certificate has the same identity to macOS, so the Accessibility permission
# and Keychain access you grant once keep working after a rebuild (an ad-hoc signature changes with every build).
# build.sh picks the certificate up by name; override it with SIGN_IDENTITY=... ./build.sh mac
set -euo pipefail
cd "$(dirname "$0")"

NAME="${SIGN_IDENTITY:-Quili Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
EXPORT=0; [[ "${1:-}" == "--export" ]] && EXPORT=1

if [[ "$(uname)" != "Darwin" ]]; then echo "error: macOS only." >&2; exit 1; fi

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists and is trusted for code signing; nothing to do."
    [[ $EXPORT -eq 1 ]] && echo "To export it for CI, use Keychain Access: right-click the certificate -> Export (.p12)."
    exit 0
fi

# Imported earlier but never trusted (an interrupted run): macOS refuses to sign with an untrusted certificate.
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is in your keychain but not trusted yet; trusting it (macOS asks for your login password)."
    TMP_PEM="$(mktemp)"; security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP_PEM"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP_PEM"
    rm -f "$TMP_PEM"
    security find-identity -v -p codesigning | grep "\"$NAME\"" && echo "Done." && exit 0
    echo "error: still not valid; delete \"$NAME\" in Keychain Access and run this again." >&2; exit 1
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS="$(uuidgen)"

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/cert.p12" -passout "pass:$PASS"

# The private key may be used by codesign without asking every time.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trust it for code signing (macOS asks for your login password here).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "\"$NAME\"" || { echo "error: \"$NAME\" is not a valid code-signing identity (was the trust prompt cancelled?). Run this script again." >&2; exit 1; }
echo "Done. build.sh will now sign with \"$NAME\"."
echo "The first build may ask to let codesign use the key: choose Always Allow."

if [[ $EXPORT -eq 1 ]]; then
    OUT="$PWD/QuiliDev.p12"
    CI_PASS="$(uuidgen)"
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$OUT" -passout "pass:$CI_PASS"
    echo
    echo "Wrote $OUT (keep it private; *.p12 is git-ignored). For signed GitHub releases add two repo secrets:"
    echo "  MACOS_CERT_P12      = $(base64 < "$OUT" | tr -d '\n' | cut -c1-24)...   (full value: base64 < QuiliDev.p12)"
    echo "  MACOS_CERT_PASSWORD = $CI_PASS"
fi
