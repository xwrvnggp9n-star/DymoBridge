#!/bin/bash
# Generates a per-machine local CA + localhost leaf cert for dymo-bridge TLS,
# and bundles the leaf into identity.p12. Run once per machine (install.sh
# calls this). Output dir defaults to /usr/local/etc/dymo-bridge.
set -euo pipefail

OUT="${1:-/usr/local/etc/dymo-bridge}"
mkdir -p "$OUT"
cd "$OUT"

if [[ -f leaf.pem && -f leaf.key ]]; then
    echo "leaf.pem/leaf.key already exist in $OUT — leaving as-is (delete them to regenerate)"
    exit 0
fi

# CA (20 years, stays on this machine only)
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -keyout ca.key -out ca.pem \
    -subj "/CN=DymoBridge Local CA ($(hostname -s))/O=Sklar/OU=DymoBridge" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

# Leaf for localhost (10 years; locally-trusted roots aren't subject to the
# 398-day public-CA limit)
openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout leaf.key -out leaf.csr \
    -subj "/CN=localhost/O=Sklar/OU=DymoBridge" 2>/dev/null

cat > leaf.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF

openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out leaf.pem -days 3650 -sha256 -extfile leaf.ext 2>/dev/null

# The CA key is only needed to mint the leaf; remove it so it can't sign
# anything else. Keep ca.pem for keychain trust and leaf.pem/leaf.key for the
# daemon (served in-memory by NIOSSL — never imported into a keychain).
rm -f ca.key leaf.csr leaf.ext ca.srl
chmod 600 leaf.key
chmod 644 ca.pem leaf.pem

echo "wrote $OUT/{ca.pem,leaf.pem,leaf.key}"
echo "next: trust the CA (install.sh does this):"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $OUT/ca.pem"
