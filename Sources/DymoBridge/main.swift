import Foundation

// dymo-bridge: native Apple Silicon replacement for DYMO.WebApi.Mac.Host.app.
// Serves the DYMO DLS web-service API on 127.0.0.1 so browser pages using the
// DYMO JS framework (e.g. Kipu in Chrome) can print to a LabelWriter via CUPS.

let VERSION = "1.0.0"

struct Config {
    var port: UInt16 = 41951
    var useTLS = true
    var certPath = "/usr/local/etc/dymo-bridge/leaf.pem"
    var keyPath = "/usr/local/etc/dymo-bridge/leaf.key"
    var queueOverride: String? = nil
    var dryRun = false
    var rotate180 = true   // match vendor print orientation
    var adjustTemplates = true
    var captureDir = ("~/Library/Logs/DymoBridge" as NSString).expandingTildeInPath
}

var config = Config()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--port":     config.port = UInt16(args.removeFirst()) ?? config.port
    case "--http":     config.useTLS = false
    case "--cert":     config.certPath = args.removeFirst()
    case "--key":      config.keyPath = args.removeFirst()
    case "--queue":    config.queueOverride = args.removeFirst()
    case "--dry-run":  config.dryRun = true
    case "--no-rotate180": config.rotate180 = false
    case "--no-adjust": config.adjustTemplates = false
    case "--capture-dir": config.captureDir = args.removeFirst()
    case "--version":  print(VERSION); exit(0)
    case "--help", "-h":
        print("""
        dymo-bridge \(VERSION) — native DYMO web-service replacement
        --port N          listen port (default 41951)
        --http            serve plain HTTP (dev only; production must be TLS)
        --cert PATH       server certificate PEM (default /usr/local/etc/dymo-bridge/leaf.pem)
        --key PATH        server private key PEM (default /usr/local/etc/dymo-bridge/leaf.key)
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
do {
    let server = try HTTPServer(port: config.port,
                                certPath: config.useTLS ? config.certPath : nil,
                                keyPath: config.useTLS ? config.keyPath : nil) { req in
        service.handle(req)
    }
    try server.start()
} catch {
    Log.error("fatal: \(error)")
    exit(1)
}

Log.info("listening on \(config.useTLS ? "https" : "http")://127.0.0.1:\(config.port)")
dispatchMain()
