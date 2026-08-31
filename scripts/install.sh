#!/bin/bash
# DymoBridge installer. Run from the repo root on the target Mac:
#   sudo ./scripts/install.sh
# Installs the binary + LaunchAgent, generates and trusts per-machine TLS
# certs, and disables the vendor DYMO web service (reversibly).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "run with sudo"; exit 1; fi
cd "$(dirname "$0")/.."

CONSOLE_UID="$(stat -f%u /dev/console)"
CONSOLE_USER="$(stat -f%Su /dev/console)"
ETC=/usr/local/etc/dymo-bridge

echo "==> building release binary"
sudo -u "$CONSOLE_USER" swift build -c release
install -m 755 .build/release/dymo-bridge /usr/local/bin/dymo-bridge

echo "==> generating TLS identity (if needed)"
./scripts/make-certs.sh "$ETC"
chown -R "$CONSOLE_USER" "$ETC"

echo "==> trusting local CA in System keychain"
security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ETC/ca.pem"

echo "==> disabling vendor DYMO web service (reversible)"
VENDOR=/Library/LaunchAgents/com.dymo.dcd.webservice.plist
if [[ -f "$VENDOR" ]]; then
    launchctl bootout "gui/$CONSOLE_UID" "$VENDOR" 2>/dev/null || true
    mv "$VENDOR" "$VENDOR.disabled"
fi
pkill -f DYMO.WebApi.Mac.Host 2>/dev/null || true

echo "==> installing LaunchAgent"
install -m 644 deploy/com.sklar.dymo-bridge.plist /Library/LaunchAgents/
launchctl bootout "gui/$CONSOLE_UID" /Library/LaunchAgents/com.sklar.dymo-bridge.plist 2>/dev/null || true
launchctl bootstrap "gui/$CONSOLE_UID" /Library/LaunchAgents/com.sklar.dymo-bridge.plist

sleep 2
echo "==> verifying"
if curl -s --max-time 5 https://127.0.0.1:41951/DYMO/DLS/Printing/StatusConnected | grep -q true; then
    echo "OK: dymo-bridge is serving on https://127.0.0.1:41951"
    echo "Health page: https://127.0.0.1:41951/"
else
    echo "WARNING: service did not answer on 41951 — check /tmp/dymo-bridge.err"
    exit 1
fi
