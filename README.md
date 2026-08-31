# DymoBridge

Native Apple Silicon replacement for `DYMO.WebApi.Mac.Host.app` (DYMO Web Services), so Kipu in Chrome can print to DYMO LabelWriter 550 printers without Rosetta and without the vendor's fragile install. The browser-side DYMO JS framework talks to `https://127.0.0.1:41951` unchanged; DymoBridge answers the same API (`StatusConnected`, `GetPrinters`, `PrintLabel`, `RenderLabel`), renders the DLS label XML with CoreGraphics/CoreText, and prints via `lp` through DYMO's own CUPS driver chain — which ships arm64-native, so the 550's genuine-label handshake keeps working.

## Build / run

- Swift + SwiftNIO/NIOSSL (only deps): `swift build -c release` → single `dymo-bridge` binary.
- Deploy: `sudo ./scripts/install.sh` — builds, generates + trusts a per-machine local CA (replaces DYMO's shared cert scheme), disables the vendor web service (reversibly), installs a LaunchAgent. `sudo ./scripts/uninstall.sh` restores the vendor setup.
- Dev: `.build/debug/dymo-bridge --http --port 41952 --dry-run` (see `--help`).
- Prereq on target Macs: DYMO's CUPS driver + a working LabelWriter print queue (from DYMO Connect installer; the vendor's web-service component is what gets disabled).

## Architecture

- `HTTPServer.swift` — HTTP/1.1 over SwiftNIO, loopback-only, TLS served by NIOSSL from plain PEM files, permissive CORS (browser pages call cross-origin). Deliberately NO keychain anywhere in the TLS path: keychain-held server identities on modern macOS produce permission dialogs a background daemon can't answer (imported-key ACLs pin to the exact importing binary, CLI-imported keys get Apple-only partition lists, and programmatic scratch keychains prompt for their password).
- `DymoService.swift` — DLS API routes; captures every print/render request (XMLs + rendered PNG) to `~/Library/Logs/DymoBridge/captures/` for replay/tuning; `https://127.0.0.1:41951/` is a human health page.
- `LabelModel.swift` / `LabelRenderer.swift` / `Barcode.swift` — DieCutLabel XML → 300 dpi PNG (text w/ shrink-to-fit, Code 128/QR via CoreImage, Code 39 native, images, shapes; labelSet substitutions).
- `PrintQueue.swift` — queue discovery via `lpstat`, media keyword derived from label twips (`w79h252` = points), submit via `lp`.

Status: API + renderer + TLS verified locally against the vendor service's behavior; awaiting first capture of real Kipu traffic to confirm framework variant + label format, then office pilot. Origin story: vendor app is Intel-only (Rosetta EOL risk) and its cert/install scheme breaks on macOS updates.
