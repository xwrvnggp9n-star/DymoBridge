# DymoBridge

Native Apple Silicon replacement for DYMO Web Services (`DYMO.WebApi.Mac.Host.app`), the Intel-only background service that browser apps use to print DYMO labels. Web apps built on DYMO's JS framework (EMRs like Kipu, label designers, custom pages) talk to `https://127.0.0.1:41951` unchanged; DymoBridge answers the same DLS API (`StatusConnected`, `GetPrinters`, `PrintLabel`, `RenderLabel`), renders the DLS label XML natively with CoreGraphics/CoreText, and prints via `lp` through DYMO's own CUPS driver chain — which ships arm64-native, so the LabelWriter 550's genuine-label handshake keeps working. No Rosetta, no fragile vendor cert scheme.

Why: the vendor app is Intel-only (a Rosetta-EOL time bomb) and its shared-certificate install breaks on macOS updates. DymoBridge is a single ~10 MB Swift binary with a per-machine local CA.

## Install

Prereq on target Macs: DYMO's CUPS driver + a working LabelWriter print queue (from the DYMO Connect installer; DymoBridge replaces only the web-service component, reversibly).

- **Installer pkg** (recommended): `./scripts/build-pkg.sh` on a dev Mac → `dist/DymoBridge-<ver>.pkg`, a double-clickable installer that ships the prebuilt arm64 binary — target Macs need no dev tools. Signs + notarizes automatically when Developer ID certs and a `dymo-notary` notarytool profile are present. Its postinstall generates and trusts a per-machine local CA (820-day leaf; rerunning the pkg renews it silently), disables the vendor web service (reversibly), and starts a LaunchAgent.
- **From a checkout**: `sudo ./scripts/install.sh` — same steps, but builds from source on the target.
- **Uninstall**: `sudo /usr/local/share/dymo-bridge/uninstall.sh` (or `scripts/uninstall.sh`) — restores the vendor web service.
- Dev: `.build/debug/dymo-bridge --http --port 41952 --dry-run` (see `--help`).

## Print verification

The vendor service prints synchronously and only answers once the label is out, so web apps treat a 200 as "printed". DymoBridge does the same: after handing a label to CUPS it watches the job (via `ipptool`) until CUPS reports it completed — DYMO's filter only finishes a job once the printer has taken the data. If the job is stopped or held by CUPS, the printer reports an error condition (e.g. `com.dymo.busy-error`, `offline-report`, `media-empty`), or the job is still queued after the wait window (`--print-wait`, default 7 s, under the DYMO framework's 10 s command timeout), the job is **cancelled** and the browser gets a non-200 with a plain-language message ("Label not printed: printer says "Printer is not ready"; status: com.dymo.busy-error … unplug and reconnect its USB cable, then print again"). The DYMO JS framework turns that into a thrown error the web app shows the user, instead of a silent "success" while the job sits in a stuck queue. A paused queue is refused up front without submitting anything. Cancelling on failure means a retry after fixing the printer prints once, not twice. `--print-wait 0` restores fire-and-forget. Each capture directory gets a `result.txt` with the outcome.

## Template adjustments (optional)

Because the web app sends the label template in every request, site-local layout preferences (e.g. dropping an unused signature row, enlarging the patient block) must be applied bridge-side. Rules live in a JSON file — `--adjust PATH`, or `/usr/local/etc/dymo-bridge/adjust.json` if present; without one, labels render exactly as sent. See `examples/kipu-specimen-adjust.json` for a working example (Kipu specimen labels) and the schema comment in `Sources/DymoBridge/TemplateAdjust.swift`. To bake site rules into your installer pkg, put them at `site/adjust.json` (gitignored) before running `build-pkg.sh` — the pkg is then named `DymoBridge-<ver>-<suffix>.pkg` (suffix from `site/suffix`, default `site`) so it can't be confused with a vanilla build.

## Architecture

- Swift + SwiftNIO/NIOSSL (only dependencies): `swift build -c release` → single `dymo-bridge` binary.
- `HTTPServer.swift` — HTTP/1.1 over SwiftNIO, loopback-only, TLS served by NIOSSL from plain PEM files, permissive CORS (browser pages call cross-origin). Deliberately NO keychain anywhere in the TLS path: keychain-held server identities on modern macOS produce permission dialogs a background daemon can't answer (imported-key ACLs pin to the exact importing binary, CLI-imported keys get Apple-only partition lists, and programmatic scratch keychains prompt for their password).
- `DymoService.swift` — DLS API routes; captures every print/render request (XMLs + rendered PNG) to `~/Library/Logs/DymoBridge/captures/` for replay/tuning; `https://127.0.0.1:41951/` is a human health page.
- `LabelModel.swift` / `LabelRenderer.swift` / `Barcode.swift` — DieCutLabel XML → 300 dpi PNG (text with shrink-to-fit, Code 128/QR via CoreImage, Code 39 native, images, shapes; labelSet substitutions). Renderer calibrated pixel-wise against the vendor engine's RenderLabel output; labels print 180°-rotated to match vendor behavior (`--no-rotate180` disables).
- `PrintQueue.swift` — queue discovery via `lpstat`, media keyword derived from label twips, submit via `lp`, then job/printer state via `ipptool -X` (plist output) until the job completes; `cancel` on failure.
- `TemplateAdjust.swift` — the config-driven template adjustments described above.

## License

MIT — see `LICENSE`.
