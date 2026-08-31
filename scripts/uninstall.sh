#!/bin/bash
# Removes DymoBridge and restores the vendor DYMO web service.
#   sudo ./scripts/uninstall.sh
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "run with sudo"; exit 1; fi

CONSOLE_UID="$(stat -f%u /dev/console)"

launchctl bootout "gui/$CONSOLE_UID" /Library/LaunchAgents/com.sklar.dymo-bridge.plist 2>/dev/null || true
rm -f /Library/LaunchAgents/com.sklar.dymo-bridge.plist /usr/local/bin/dymo-bridge

if [[ -f /usr/local/etc/dymo-bridge/ca.pem ]]; then
    security remove-trusted-cert -d /usr/local/etc/dymo-bridge/ca.pem 2>/dev/null || true
fi
rm -rf /usr/local/etc/dymo-bridge

VENDOR=/Library/LaunchAgents/com.dymo.dcd.webservice.plist
if [[ -f "$VENDOR.disabled" ]]; then
    mv "$VENDOR.disabled" "$VENDOR"
    launchctl bootstrap "gui/$CONSOLE_UID" "$VENDOR" 2>/dev/null || true
    echo "vendor DYMO web service restored"
fi
echo "DymoBridge removed"
