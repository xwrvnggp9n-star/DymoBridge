import Foundation

// Talks to CUPS via its command-line tools (lpstat/lp/ipptool/cancel). The
// heavy lifting (rasterizing for the LabelWriter, USB/label handshake) is done
// by DYMO's own CUPS filter chain, which ships as universal (arm64-native)
// binaries.

struct CUPSQueue {
    var name: String          // CUPS queue name, e.g. DYMO_LabelWriter_550_Turbo
    var description: String   // human name, e.g. "DYMO LabelWriter 550 Turbo"
    var enabled: Bool
}

// IPP job-state (RFC 8011 §5.3.7).
enum IPPJobState: Int {
    case pending = 3, held = 4, processing = 5, stopped = 6, canceled = 7, aborted = 8, completed = 9
}

struct JobStatus {
    let id: Int
    let state: IPPJobState
    let stateReasons: [String]     // job-state-reasons
    let printerMessage: String     // job-printer-state-message: the filter/backend's last word on this job
    let printerReasons: [String]   // job-printer-state-reasons: set only while this job is being processed
}

struct PrinterStatus {
    static let stopped = 5         // printer-state: 3 idle, 4 processing, 5 stopped (paused)
    let state: Int
    let reasons: [String]          // printer-state-reasons. Can be stale: CUPS keeps the last backend report.
    let message: String            // printer-state-message
    let acceptingJobs: Bool
}

enum SubmitResult {
    case submitted(jobId: Int?)    // nil: lp accepted the job but its id could not be parsed
    case dryRun
    case failed(String)
}

enum PrintOutcome {
    case printed
    case failed(String)            // human-readable reason; the job has been cancelled
    case unverified                // CUPS could not be queried; fall back to fire-and-forget
}

enum PrintQueue {

    // Where the small ipptool request files live (set to the capture dir at startup).
    static var workDir = NSTemporaryDirectory()

    static func run(_ tool: String, _ args: [String], discardStderr: Bool = false) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = discardStderr ? FileHandle.nullDevice : pipe
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

    // MARK: - submit

    static func submit(pngPath: String, queue: String, media: String, copies: Int, title: String, dryRun: Bool) -> SubmitResult {
        if dryRun {
            Log.info("dry-run: would print \(pngPath) to \(queue) media=\(media) copies=\(copies)")
            return .dryRun
        }
        var args = ["-d", queue, "-o", "media=\(media)", "-o", "fit-to-page", "-t", title]
        if copies > 1 { args += ["-n", "\(copies)"] }
        args.append(pngPath)
        let (out, code) = run("/usr/bin/lp", args)
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0 else {
            Log.error("lp failed (\(code)): \(text)")
            return .failed(text.isEmpty ? "lp exited with status \(code)" : text)
        }
        Log.info("submitted to \(queue): \(text)")
        // "request id is DYMO_LabelWriter_550_Turbo-3110 (1 file(s))"
        guard let range = text.range(of: "request id is \(queue)-"),
              let id = Int(text[range.upperBound...].prefix { $0.isNumber }) else {
            Log.error("could not parse job id from lp output: \(text)")
            return .submitted(jobId: nil)
        }
        return .submitted(jobId: id)
    }

    // MARK: - job / printer status (ipptool, plist output)

    private static func testFile(_ name: String, _ body: String) -> String {
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        let path = (workDir as NSString).appendingPathComponent("ipptool-\(name).test")
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
    private static let jobTest = testFile("get-job", """
        {
            OPERATION get-job-attributes
            GROUP operation
            ATTR charset attributes-charset utf-8
            ATTR language attributes-natural-language en
            ATTR uri job-uri $uri
            ATTR keyword requested-attributes job-id,job-state,job-state-reasons,job-printer-state-message,job-printer-state-reasons
        }
        """)
    private static let printerTest = testFile("get-printer", """
        {
            OPERATION get-printer-attributes
            GROUP operation
            ATTR charset attributes-charset utf-8
            ATTR language attributes-natural-language en
            ATTR uri printer-uri $uri
            ATTR keyword requested-attributes printer-state,printer-state-reasons,printer-state-message,printer-is-accepting-jobs
        }
        """)

    // ipptool -X prints a plist: Tests[0].ResponseAttributes is one dict per
    // attribute group; single values are scalars, multi-values arrays.
    private static func ippAttributes(uri: String, test: String, groupKey: String) -> [String: Any]? {
        let (out, _) = run("/usr/bin/ipptool", ["-X", uri, test], discardStderr: true)
        guard let data = out.data(using: .utf8),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let tests = plist["Tests"] as? [[String: Any]],
              let groups = tests.first?["ResponseAttributes"] as? [[String: Any]]
        else { return nil }
        return groups.first { $0[groupKey] != nil }
    }

    private static func strings(_ v: Any?) -> [String] {
        if let s = v as? String { return [s] }
        if let a = v as? [Any] { return a.compactMap { $0 as? String } }
        return []
    }

    static func jobStatus(id: Int) -> JobStatus? {
        guard let a = ippAttributes(uri: "ipp://localhost/jobs/\(id)", test: jobTest, groupKey: "job-state"),
              let raw = a["job-state"] as? Int, let state = IPPJobState(rawValue: raw) else { return nil }
        return JobStatus(id: id, state: state,
                         stateReasons: strings(a["job-state-reasons"]).filter { $0 != "none" },
                         printerMessage: (a["job-printer-state-message"] as? String) ?? "",
                         printerReasons: strings(a["job-printer-state-reasons"]).filter { $0 != "none" })
    }

    static func printerStatus(queue: String) -> PrinterStatus? {
        guard let a = ippAttributes(uri: "ipp://localhost/printers/\(queue)", test: printerTest, groupKey: "printer-state"),
              let state = a["printer-state"] as? Int else { return nil }
        return PrinterStatus(state: state,
                             reasons: strings(a["printer-state-reasons"]).filter { $0 != "none" },
                             message: (a["printer-state-message"] as? String) ?? "",
                             acceptingJobs: (a["printer-is-accepting-jobs"] as? Bool) ?? true)
    }

    // Jobs still sitting on this queue (pending/processing/held/stopped).
    static func queuedJobCount(queue: String) -> Int {
        let (out, code) = run("/usr/bin/lpstat", ["-o", queue])
        guard code == 0 else { return 0 }
        return out.components(separatedBy: "\n").filter { $0.hasPrefix("\(queue)-") }.count
    }

    // State reasons that mean nothing prints until a human intervenes. IPP
    // severity suffixes are -error / -warning / -report; DYMO's filter reports
    // e.g. com.dymo.busy-error, the CUPS usb backend offline-report.
    static func isErrorReason(_ r: String) -> Bool {
        if r.hasSuffix("-error") { return true }
        return ["offline-report", "paused", "shutdown", "media-empty", "media-needed", "media-jam",
                "cover-open", "door-open", "input-tray-missing", "timed-out"].contains(r)
    }

    // MARK: - wait for the label to actually come out

    // DYMO's filter only finishes a job once the printer has taken the data, so
    // job-state=completed means the label printed. Anything else — CUPS stopping
    // or holding the job, the printer reporting an error, or the job simply not
    // completing inside the window — is reported as a failure, and the job is
    // cancelled so that a retry after the printer is fixed doesn't print twice.
    static func waitForCompletion(jobId: Int, queue: String, timeout: TimeInterval, copies: Int) -> PrintOutcome {
        let deadline = Date().addingTimeInterval(timeout + Double(max(copies - 1, 0)) * 2)
        let pollInterval = 0.4
        var errorPolls = 0
        var last: JobStatus?
        while true {
            Thread.sleep(forTimeInterval: pollInterval)
            guard let job = jobStatus(id: jobId) else {
                Log.error("could not query CUPS for job \(jobId); assuming it will print")
                return .unverified
            }
            last = job
            switch job.state {
            case .completed:
                return .printed
            case .canceled, .aborted, .stopped, .held:
                return fail(job: job, queue: queue, waited: nil)
            case .pending, .processing:
                // Fast-fail on an error the filter/backend reports for *this* job
                // (a new job's own reasons start empty, so they can't be stale).
                // The usb backend flags offline-report while it waits for a
                // printer that is merely slow to answer (e.g. right after a
                // reconnect), so require the error to persist for ~3 s — longer
                // than a healthy label takes to print — before giving up early.
                if job.printerReasons.contains(where: isErrorReason) {
                    errorPolls += 1
                    if Double(errorPolls) * pollInterval >= 3 { return fail(job: job, queue: queue, waited: nil) }
                } else {
                    errorPolls = 0
                }
            }
            if Date() >= deadline { break }
        }
        return fail(job: last, queue: queue, waited: timeout)
    }

    private static func fail(job: JobStatus?, queue: String, waited: TimeInterval?) -> PrintOutcome {
        let printer = printerStatus(queue: queue)
        if let job = job, job.state != .canceled, job.state != .aborted {
            // If it completed between our last poll and the cancel, it printed after all.
            if cancel(jobId: job.id, queue: queue) == .alreadyCompleted { return .printed }
        }
        var parts: [String] = []
        if let job = job {
            switch job.state {
            case .canceled: parts.append("the print job was cancelled")
            case .aborted: parts.append("CUPS aborted the print job")
            case .stopped, .held: parts.append("CUPS stopped the print job")
            default: break
            }
            if !job.printerMessage.isEmpty { parts.append("printer says \"\(job.printerMessage)\"") }
        }
        var reasons = job?.printerReasons ?? []
        for r in printer?.reasons ?? [] where !reasons.contains(r) { reasons.append(r) }
        if !reasons.isEmpty { parts.append("status: \(reasons.joined(separator: ", "))") }
        if let w = waited { parts.append("not printed after \(Int(w.rounded())) s") }
        let others = queuedJobCount(queue: queue)
        if others > 0 { parts.append("\(others) other job(s) waiting in the print queue") }
        let detail = parts.isEmpty ? "the print queue did not report the label as printed" : parts.joined(separator: "; ")
        let message = "Label not printed: \(detail). Check the DYMO printer (labels loaded, cover closed, power light on) "
            + "or unplug and reconnect its USB cable, then print again."
        return .failed(message)
    }

    enum CancelResult { case cancelled, alreadyCompleted, failed }

    static func cancel(jobId: Int, queue: String) -> CancelResult {
        let (out, code) = run("/usr/bin/cancel", ["\(queue)-\(jobId)"])
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if code == 0 {
            Log.info("cancelled job \(queue)-\(jobId)")
            return .cancelled
        }
        if text.contains("already completed") {
            Log.info("job \(queue)-\(jobId) completed before it could be cancelled")
            return .alreadyCompleted
        }
        Log.error("cancel \(queue)-\(jobId) failed (\(code)): \(text)")
        return .failed
    }

    // Message for a queue that is paused/stopped: nothing prints until someone
    // resumes it (DYMO's pnpd does so when the printer reappears on USB).
    static func pausedMessage(queue: String, printer: PrinterStatus) -> String {
        let why = printer.reasons.isEmpty ? "" : " (\(printer.reasons.joined(separator: ", ")))"
        let what = printer.state == PrinterStatus.stopped ? "is paused" : "is not accepting jobs"
        return "Label not printed: the print queue \(queue) \(what)\(why). Reconnect the printer, "
            + "or resume the queue in System Settings > Printers & Scanners, then print again."
    }
}
