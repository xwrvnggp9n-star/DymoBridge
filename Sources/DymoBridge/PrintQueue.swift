import Foundation

// Talks to CUPS via lpstat/lp. The heavy lifting (rasterizing for the
// LabelWriter, USB/label handshake) is done by DYMO's own CUPS filter chain,
// which ships as universal (arm64-native) binaries.

struct CUPSQueue {
    var name: String          // CUPS queue name, e.g. DYMO_LabelWriter_550_Turbo
    var description: String   // human name, e.g. "DYMO LabelWriter 550 Turbo"
    var enabled: Bool
}

enum PrintQueue {

    static func run(_ tool: String, _ args: [String]) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    // All CUPS queues that look like DYMO label printers.
    static func discover() -> [CUPSQueue] {
        let (out, code) = run("/usr/bin/lpstat", ["-p"])
        guard code == 0 else { return [] }
        var queues: [CUPSQueue] = []
        for line in out.components(separatedBy: "\n") {
            // "printer DYMO_LabelWriter_550_Turbo is idle.  enabled since ..."
            guard line.hasPrefix("printer ") else { continue }
            let parts = line.dropFirst("printer ".count).split(separator: " ", maxSplits: 1)
            guard let name = parts.first.map(String.init) else { continue }
            let lower = name.lowercased()
            guard lower.contains("dymo") || lower.contains("labelwriter") else { continue }
            let enabled = !line.contains("disabled")
            queues.append(CUPSQueue(name: name,
                                    description: describe(queue: name) ?? name.replacingOccurrences(of: "_", with: " "),
                                    enabled: enabled))
        }
        return queues
    }

    private static func describe(queue: String) -> String? {
        let (out, code) = run("/usr/bin/lpstat", ["-l", "-p", queue])
        guard code == 0 else { return nil }
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Description:") {
                let d = t.dropFirst("Description:".count).trimmingCharacters(in: .whitespaces)
                if !d.isEmpty { return d }
            }
        }
        return nil
    }

    // Find the queue whose CUPS name or description matches the printer name
    // the browser framework passes back (it uses our GetPrinters <Name>).
    static func match(printerName: String, queues: [CUPSQueue]) -> CUPSQueue? {
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let want = norm(printerName)
        return queues.first { norm($0.description) == want || norm($0.name) == want }
            ?? queues.first
    }

    // DYMO PPD PageSize keywords are "w{width}h{height}" in printer points
    // (1/72"). Label XML dimensions are twips (1/1440") → points = twips / 20.
    static func mediaKeyword(labelWidthTwips: Double, labelHeightTwips: Double) -> String {
        let w = Int((labelWidthTwips / 20).rounded())
        let h = Int((labelHeightTwips / 20).rounded())
        // Media is always named portrait-style: width (across feed) < height (length).
        return w <= h ? "w\(w)h\(h)" : "w\(h)h\(w)"
    }

    @discardableResult
    static func submit(pngPath: String, queue: String, media: String, copies: Int, title: String, dryRun: Bool) -> Bool {
        if dryRun {
            Log.info("dry-run: would print \(pngPath) to \(queue) media=\(media) copies=\(copies)")
            return true
        }
        var args = ["-d", queue, "-o", "media=\(media)", "-o", "fit-to-page", "-t", title]
        if copies > 1 { args += ["-n", "\(copies)"] }
        args.append(pngPath)
        let (out, code) = run("/usr/bin/lp", args)
        if code == 0 {
            Log.info("submitted to \(queue): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            return true
        } else {
            Log.error("lp failed (\(code)): \(out)")
            return false
        }
    }
}
