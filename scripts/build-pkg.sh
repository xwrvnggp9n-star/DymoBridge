#!/bin/bash
# Builds the double-clickable installer: dist/DymoBridge-<version>.pkg
# Run on the dev Mac (needs Xcode CLT): ./scripts/build-pkg.sh
# The pkg ships the prebuilt arm64 binary, so target Macs need no dev tools —
# its postinstall does what install.sh does (certs, CA trust, vendor disable,
# LaunchAgent), but via Installer.app's GUI password prompt instead of sudo.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^let VERSION = "\(.*\)"$/\1/p' Sources/DymoBridge/main.swift)"
[[ -n "$VERSION" ]] || { echo "could not read VERSION from main.swift"; exit 1; }

echo "==> building release binary ($VERSION, arm64)"
swift build -c release --arch arm64

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/root"
SCRIPTS="$STAGE/scripts"

install -d "$ROOT/usr/local/bin" "$ROOT/usr/local/share/dymo-bridge" \
    "$ROOT/Library/LaunchAgents" "$SCRIPTS" build dist
install -m 755 .build/arm64-apple-macosx/release/dymo-bridge "$ROOT/usr/local/bin/dymo-bridge"
install -m 644 deploy/com.sklar.dymo-bridge.plist "$ROOT/Library/LaunchAgents/"
install -m 755 scripts/uninstall.sh "$ROOT/usr/local/share/dymo-bridge/uninstall.sh"
install -m 755 pkg/scripts/preinstall pkg/scripts/postinstall "$SCRIPTS/"
install -m 755 scripts/make-certs.sh "$SCRIPTS/make-certs.sh"

echo "==> pkgbuild"
pkgbuild --root "$ROOT" --scripts "$SCRIPTS" \
    --identifier com.sklar.dymo-bridge --version "$VERSION" \
    --install-location / build/core.pkg

echo "==> productbuild"
sed "s/__VERSION__/$VERSION/" pkg/distribution.xml > build/distribution.xml
productbuild --distribution build/distribution.xml \
    --resources pkg/resources --package-path build \
    "dist/DymoBridge-$VERSION.pkg"

echo "wrote dist/DymoBridge-$VERSION.pkg"
