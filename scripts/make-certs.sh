#!/bin/bash
# Generates a per-machine local CA + localhost leaf cert for dymo-bridge TLS.
# Output dir defaults to /usr/local/etc/dymo-bridge; install.sh and the pkg
# postinstall call this on every run.
#
# The leaf is capped at 820 days: Apple limits TLS server certs to 825 days
# and Safari enforces that even for locally-trusted CAs (Chrome does not,
# which is how a 10-year leaf once slipped through unnoticed). The CA key is
# KEPT (root-only) so renewal mints a fresh leaf under the already-trusted CA
# with no new admin trust prompt — rerunning the installer renews; a leaf
# with more than 30 days left is left alone.
set -euo pipefail

OUT="${1:-/usr/local/etc/dymo-bridge}"
mkdir -p "$OUT"
cd "$OUT"

if [[ -f leaf.pem && -f leaf.key ]] && openssl x509 -in leaf.pem -checkend 2592000 >/dev/null 2>&1; then
    echo "leaf.pem valid for >30 more days — leaving as-is (delete it to force regeneration)"
    exit 0
fi

NEW_CA=0
if [[ ! -f ca.pem || ! -f ca.key ]]; then
    NEW_CA=1
    # CA (20 years, stays on this machine only)
    openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
        -keyout ca.key -out ca.pem \
        -subj "/CN=DymoBridge Local CA ($(hostname -s))/O=Sklar/OU=DymoBridge" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
fi

openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout leaf.key.new -out leaf.csr \
    -subj "/CN=localhost/O=Sklar/OU=DymoBridge" 2>/dev/null

cat > leaf.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF

openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out leaf.pem -days 820 -sha256 -extfile leaf.ext 2>/dev/null
mv leaf.key.new leaf.key

rm -f leaf.csr leaf.ext ca.srl
chmod 600 ca.key leaf.key
chmod 644 ca.pem leaf.pem

echo "wrote $OUT/{ca.pem,ca.key,leaf.pem,leaf.key} (leaf valid 820 days)"
if [[ "$NEW_CA" -eq 1 ]]; then
    echo "new CA — it must be trusted (install.sh / the pkg postinstall do this):"
    echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $OUT/ca.pem"
else
    echo "leaf renewed under the existing (already-trusted) CA"
fi
