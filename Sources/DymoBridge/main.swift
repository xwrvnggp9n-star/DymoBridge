import Foundation

// dymo-bridge: native Apple Silicon replacement for DYMO.WebApi.Mac.Host.app.
// Serves the DYMO DLS web-service API on 127.0.0.1 so browser pages using the
// DYMO JS framework (e.g. Kipu in Chrome) can print to a LabelWriter via CUPS.

let VERSION = "1.3.0"

struct Config {
    var port: UInt16 = 41951
    var useTLS = true
    var certPath = "/usr/local/etc/dymo-bridge/leaf.pem"
    var keyPath = "/usr/local/etc/dymo-bridge/leaf.key"
    var queueOverride: String? = nil
    var dryRun = false
    var rotate180 = true   // match vendor print orientation
    var adjustTemplates = true
    var adjustPath: String? = nil   // nil → use default path if the file exists
    var captureDir = ("~/Library/Logs/DymoBridge" as NSString).expandingTildeInPath
    // Seconds to wait for CUPS to finish each label before telling the browser it
    // failed (0 = fire-and-forget). Kept under the DYMO framework's 10 s async
    // command timeout so a failure is reported, not timed out.
    var printWait: TimeInterval = 7
}
let DEFAULT_ADJUST_PATH = "/usr/local/etc/dymo-bridge/adjust.json"

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
    case "--adjust":   config.adjustPath = args.removeFirst()
    case "--capture-dir": config.captureDir = args.removeFirst()
    case "--print-wait": config.printWait = Double(args.removeFirst()) ?? config.printWait
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
        --adjust PATH     template-adjustment rules JSON (default \(DEFAULT_ADJUST_PATH) if present)
        --no-adjust       disable template adjustments even if a rules file exists
        --no-rotate180    print in template orientation instead of the vendor's 180° rotation
        --capture-dir DIR log/capture directory (default ~/Library/Logs/DymoBridge)
        --print-wait SEC  seconds to wait for CUPS to finish each label; a job that stalls,
                          errors or is still queued after SEC is cancelled and reported to the
                          browser as a failure (default 7; 0 = report success on submission)
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

try? FileManager.default.createDirectory(atPath: config.captureDir, withIntermediateDirectories: true)
Log.setup(dir: config.captureDir)
if config.adjustTemplates {
    if let path = config.adjustPath {
        TemplateAdjust.load(path: path)
    } else if FileManager.default.fileExists(atPath: DEFAULT_ADJUST_PATH) {
        TemplateAdjust.load(path: DEFAULT_ADJUST_PATH)
    }
}
PrintQueue.workDir = config.captureDir
Log.info("dymo-bridge \(VERSION) starting; port=\(config.port) tls=\(config.useTLS) dryRun=\(config.dryRun) printWait=\(config.printWait)s")

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
