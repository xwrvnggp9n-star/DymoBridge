import Foundation

// dymo-bridge: native Apple Silicon replacement for DYMO.WebApi.Mac.Host.app.
// Serves the DYMO DLS web-service API on 127.0.0.1 so browser pages using the
// DYMO JS framework (e.g. Kipu in Chrome) can print to a LabelWriter via CUPS.

let VERSION = "0.1.0"

struct Config {
    var port: UInt16 = 41951
    var useTLS = true
    var useKeychainIdentity = false
    var p12Path = "/usr/local/etc/dymo-bridge/identity.p12"
    var p12PassPath = "/usr/local/etc/dymo-bridge/identity.pass"
    var queueOverride: String? = nil
    var dryRun = false
    var captureDir = ("~/Library/Logs/DymoBridge" as NSString).expandingTildeInPath
}

var config = Config()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--port":     config.port = UInt16(args.removeFirst()) ?? config.port
    case "--http":     config.useTLS = false
    case "--keychain": config.useKeychainIdentity = true
    case "--p12":      config.p12Path = args.removeFirst()
    case "--p12-pass": config.p12PassPath = args.removeFirst()
    case "--queue":    config.queueOverride = args.removeFirst()
    case "--dry-run":  config.dryRun = true
    case "--capture-dir": config.captureDir = args.removeFirst()
    case "--version":  print(VERSION); exit(0)
    case "--help", "-h":
        print("""
        dymo-bridge \(VERSION) — native DYMO web-service replacement
        --port N          listen port (default 41951)
        --http            serve plain HTTP (dev only; production must be TLS)
        --keychain        use the existing CN=localhost SSL identity from the keychain
                          (e.g. DYMO's own trusted cert) instead of a p12 file
        --p12 PATH        PKCS#12 identity for TLS (default /usr/local/etc/dymo-bridge/identity.p12)
        --p12-pass PATH   file containing the p12 passphrase
        --queue NAME      force a CUPS queue instead of auto-discovering DYMO queues
        --dry-run         render labels but do not submit to CUPS
        --capture-dir DIR log/capture directory (default ~/Library/Logs/DymoBridge)
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

try? FileManager.default.createDirectory(atPath: config.captureDir, withIntermediateDirectories: true)
Log.setup(dir: config.captureDir)
Log.info("dymo-bridge \(VERSION) starting; port=\(config.port) tls=\(config.useTLS) dryRun=\(config.dryRun)")

let service = DymoService(config: config)
let server: HTTPServer
do {
    var identity: SecIdentity? = nil
    if config.useTLS {
        if config.useKeychainIdentity {
            identity = try TLSIdentity.loadFromKeychain(commonName: "localhost")
        } else {
            identity = try TLSIdentity.load(p12Path: config.p12Path, passPath: config.p12PassPath)
            Log.info("loaded TLS identity from \(config.p12Path)")
        }
    }
    server = try HTTPServer(port: config.port, identity: identity) { req in
        service.handle(req)
    }
    try server.start()
} catch {
    Log.error("fatal: \(error)")
    exit(1)
}

Log.info("listening on \(config.useTLS ? "https" : "http")://127.0.0.1:\(config.port)")
dispatchMain()
