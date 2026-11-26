#!/bin/bash
# Regenerates the test-only TLS certificates in DionysusPlayerTests/Fixtures/TLS.
# Needs Homebrew OpenSSL 3 or later: its PKCS#12 default (AES-256-CBC, SHA-256
# MAC) is what SecPKCS12Import accepts; the older RC2 default isn't.
set -euo pipefail

OPENSSL=${OPENSSL:-/opt/homebrew/bin/openssl}
OUT="$(cd "$(dirname "$0")/.." && pwd)/DionysusPlayerTests/Fixtures/TLS"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
PASS=dionysus
# About 20 years, so the fixtures outlive any clock a test could run under.
DAYS=7305
# CA-issued server leaves can't be valid for more than 825 days: Apple's TLS
# policy refuses a longer one even under a custom anchor. Tests that evaluate
# them pin a verify date inside this window, so they don't rot.
LEAF_DAYS=800

# Self-signed pair: a DNS SAN equal to the CN, so a host name check would pass.
selfsigned() { # name cn
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
    -keyout "$WORK/$1.key" -out "$WORK/$1.pem" -subj "/CN=$2" \
    -addext "subjectAltName=DNS:$2" -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" 2>/dev/null
  "$OPENSSL" x509 -in "$WORK/$1.pem" -outform der -out "$OUT/$1.der"
  "$OPENSSL" pkcs12 -export -inkey "$WORK/$1.key" -in "$WORK/$1.pem" \
    -name "$1" -passout "pass:$PASS" -out "$OUT/$1.p12"
}
selfsigned selfSignedA selfsigned-a.dionysus.test
selfsigned selfSignedB selfsigned-b.dionysus.test

# Test CA.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
  -keyout "$WORK/ca.key" -out "$WORK/ca.pem" -subj "/CN=Dionysus Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
"$OPENSSL" x509 -in "$WORK/ca.pem" -outform der -out "$OUT/testCA.der"

# CA-issued leaves.
leaf() { # name cn san [p12]
  "$OPENSSL" req -newkey rsa:2048 -nodes -keyout "$WORK/$1.key" -out "$WORK/$1.csr" \
    -subj "/CN=$2" 2>/dev/null
  printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
    "$3" > "$WORK/$1.ext"
  "$OPENSSL" x509 -req -in "$WORK/$1.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" \
    -CAcreateserial -sha256 -days "$LEAF_DAYS" -extfile "$WORK/$1.ext" -out "$WORK/$1.pem" 2>/dev/null
  "$OPENSSL" x509 -in "$WORK/$1.pem" -outform der -out "$OUT/$1.der"
  if [ "${4:-}" = p12 ]; then
    "$OPENSSL" pkcs12 -export -inkey "$WORK/$1.key" -in "$WORK/$1.pem" \
      -name "$1" -passout "pass:$PASS" -out "$OUT/$1.p12"
  fi
}
leaf nameLeaf media.dionysus.test "DNS:media.dionysus.test,DNS:*.wild.dionysus.test" p12
leaf nameLeafOther other.dionysus.test "DNS:other.dionysus.test"
echo "Wrote fixtures to $OUT"
