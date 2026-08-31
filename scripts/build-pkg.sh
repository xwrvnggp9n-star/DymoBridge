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

# Signing is automatic when the Developer ID certs are in the keychain;
# notarization when a notarytool profile named "dymo-notary" exists
# (xcrun notarytool store-credentials dymo-notary --apple-id ... --team-id ...).
APP_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
INST_ID="$(security find-identity -v -p basic | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)"
NOTARY_PROFILE=dymo-notary

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

if [[ -n "$APP_ID" ]]; then
    echo "==> codesigning binary ($APP_ID)"
    # Hardened runtime + timestamp are required for notarization.
    codesign --force --options runtime --timestamp \
        --sign "$APP_ID" "$ROOT/usr/local/bin/dymo-bridge"
else
    echo "NOTE: no Developer ID Application cert — binary left unsigned"
fi

echo "==> pkgbuild"
pkgbuild --root "$ROOT" --scripts "$SCRIPTS" \
    --identifier com.sklar.dymo-bridge --version "$VERSION" \
    --install-location / build/core.pkg

echo "==> productbuild"
PKG="dist/DymoBridge-$VERSION.pkg"
sed "s/__VERSION__/$VERSION/" pkg/distribution.xml > build/distribution.xml
if [[ -n "$INST_ID" ]]; then
    productbuild --distribution build/distribution.xml \
        --resources pkg/resources --package-path build \
        --sign "$INST_ID" "$PKG"
else
    echo "NOTE: no Developer ID Installer cert — pkg left unsigned"
    productbuild --distribution build/distribution.xml \
        --resources pkg/resources --package-path build "$PKG"
fi

# Probe via notarytool itself: profiles live in the data-protection keychain,
# which `security find-generic-password` cannot see.
if [[ -n "$INST_ID" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> notarizing (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
    echo "==> Gatekeeper check"
    spctl -a -vv -t install "$PKG"
elif [[ -n "$INST_ID" ]]; then
    echo "NOTE: pkg is signed but NOT notarized — store credentials once with:"
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR-APPLE-ID --team-id 5Y3S9Y6Z27"
fi

echo "wrote $PKG"
