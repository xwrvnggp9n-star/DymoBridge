import Foundation

// Implements the DYMO DLS web-service API surface that the browser-side
// DYMO JS framework talks to. Every print request is also captured to disk
// (XML params + rendered PNG) so real-world payloads can be replayed and
// rendering tuned against ground truth.

final class DymoService {
    private let config: Config
    private let queue = DispatchQueue(label: "dymo-bridge.service")
    private var lastPrintStatus = "none yet"

    init(config: Config) {
        self.config = config
    }

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        if req.method == "OPTIONS" {
            return HTTPResponse(status: 200, body: "")
        }

        // Route on the trailing component; the framework calls
        // /DYMO/DLS/Printing/<Command>. Match case-insensitively.
        let command = req.path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""

        switch command {
        case "", "check":
            return statusPage()
        case "statusconnected":
            return HTTPResponse(body: "true")
        case "getprinters":
            return HTTPResponse(contentType: "text/xml; charset=utf-8", body: printersXML())
        case "printlabel":
            return queue.sync { printLabel(req) }
        case "renderlabel":
            return queue.sync { renderLabel(req) }
        default:
            capture(kind: "unknown-\(command)", req: req, extra: [:])
            Log.info("unhandled command '\(command)' \(req.method) \(req.path) — returned 200/true so the framework doesn't hard-fail; payload captured")
            return HTTPResponse(body: "true")
        }
    }

    // MARK: - GetPrinters

    private func printersXML() -> String {
        var queues = PrintQueue.discover()
        if let forced = config.queueOverride {
            queues = queues.filter { $0.name == forced }
        }
        var xml = "<Printers>"
        for q in queues {
            let twinTurbo = q.description.lowercased().contains("twin turbo")
            xml += "<LabelWriterPrinter>"
            xml += "<Name>\(escapeXML(q.description))</Name>"
            xml += "<ModelName>\(escapeXML(q.description))</ModelName>"
            xml += "<IsConnected>\(q.enabled ? "True" : "False")</IsConnected>"
            xml += "<IsLocal>True</IsLocal>"
            xml += "<IsTwinTurbo>\(twinTurbo ? "True" : "False")</IsTwinTurbo>"
            xml += "</LabelWriterPrinter>"
        }
        xml += "</Printers>"
        return xml
    }

    // MARK: - PrintLabel

    private func printLabel(_ req: HTTPRequest) -> HTTPResponse {
        let params = req.formParams
        let printerName = params["printerName"] ?? ""
        let labelXml = params["labelXml"] ?? ""
        let labelSetXml = params["labelSetXml"] ?? ""
        let printParamsXml = params["printParamsXml"] ?? ""

        let captureDir = capture(kind: "print", req: req, extra: [
            "printerName.txt": printerName,
            "labelXml.xml": labelXml,
            "labelSetXml.xml": labelSetXml,
            "printParamsXml.xml": printParamsXml,
        ])

        guard !labelXml.isEmpty else {
            Log.error("PrintLabel with empty labelXml")
            return HTTPResponse(status: 500, body: "false")
        }

        do {
            var label = try LabelParser.parseLabel(xml: labelXml)
            if config.adjustTemplates { TemplateAdjust.apply(&label) }
            let printParams = LabelParser.parsePrintParams(xml: printParamsXml)
            var records = LabelParser.parseLabelSet(xml: labelSetXml)
            if records.isEmpty { records = [LabelRecord(values: [:])] }

            let queues = PrintQueue.discover()
            guard let target = config.queueOverride.map({ o in queues.first { $0.name == o } }) ?? PrintQueue.match(printerName: printerName, queues: queues) else {
                Log.error("no DYMO CUPS queue found for printer '\(printerName)'")
                lastPrintStatus = "FAILED: no CUPS queue"
                return HTTPResponse(status: 500, body: "false")
            }
            let media = PrintQueue.mediaKeyword(labelWidthTwips: label.dieCutWidthTwips,
                                                labelHeightTwips: label.dieCutHeightTwips)

            var allOK = true
            for (i, record) in records.enumerated() {
                var png = try LabelRenderer.render(label: label, record: record)
                if config.rotate180 { png = try LabelRenderer.rotate180(png: png) }
                let pngPath = (captureDir as NSString).appendingPathComponent("rendered-\(i).png")
                try png.write(to: URL(fileURLWithPath: pngPath))
                let ok = PrintQueue.submit(pngPath: pngPath, queue: target.name, media: media,
                                           copies: printParams.copies, title: printParams.jobTitle,
                                           dryRun: config.dryRun)
                allOK = allOK && ok
            }
            lastPrintStatus = allOK
                ? "OK \(Date()) — \(records.count) label(s) to \(target.name) media=\(media)"
                : "FAILED submitting to \(target.name)"
            Log.info("PrintLabel: \(records.count) label(s), paper='\(label.paperName)', media=\(media), queue=\(target.name), ok=\(allOK)")
            return HTTPResponse(body: allOK ? "true" : "false")
        } catch {
            Log.error("PrintLabel failed: \(error)")
            lastPrintStatus = "FAILED: \(error)"
            return HTTPResponse(status: 500, body: "false")
        }
    }

    // MARK: - RenderLabel (browser-side label preview)

    private func renderLabel(_ req: HTTPRequest) -> HTTPResponse {
        let params = req.formParams
        let labelXml = params["labelXml"] ?? ""
        capture(kind: "render", req: req, extra: ["labelXml.xml": labelXml])
        guard !labelXml.isEmpty else { return HTTPResponse(status: 500, body: "") }
        do {
            var label = try LabelParser.parseLabel(xml: labelXml)
            if config.adjustTemplates { TemplateAdjust.apply(&label) }
            let png = try LabelRenderer.render(label: label, record: nil)
            // The DLS web service returns the PNG as a quoted base64 JSON string.
            return HTTPResponse(contentType: "application/json; charset=utf-8",
                                body: "\"\(png.base64EncodedString())\"")
        } catch {
            Log.error("RenderLabel failed: \(error)")
            return HTTPResponse(status: 500, body: "")
        }
    }

    // MARK: - status page (health check)

    private func statusPage() -> HTTPResponse {
        let queues = PrintQueue.discover()
        let queueList = queues.isEmpty ? "<li><b>NO DYMO QUEUES FOUND</b></li>"
            : queues.map { "<li>\($0.name) — \($0.description) (\($0.enabled ? "enabled" : "DISABLED"))</li>" }.joined()
        let html = """
        <html><head><title>DymoBridge</title></head><body style="font-family:-apple-system,sans-serif">
        <h2>DymoBridge \(VERSION)</h2>
        <p>Native DYMO web-service replacement. Status: <b>running</b></p>
        <ul>\(queueList)</ul>
        <p>Last print: \(escapeXML(lastPrintStatus))</p>
        <p>Logs &amp; captures: \(config.captureDir)</p>
        </body></html>
        """
        return HTTPResponse(contentType: "text/html; charset=utf-8", body: html)
    }

    // MARK: - capture

    @discardableResult
    private func capture(kind: String, req: HTTPRequest, extra: [String: String]) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = (config.captureDir as NSString)
            .appendingPathComponent("captures/\(stamp)-\(kind)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let meta = """
        \(req.method) \(req.path)
        headers: \(req.headers)
        query: \(req.query)
        """
        try? meta.write(toFile: (dir as NSString).appendingPathComponent("request.txt"),
                        atomically: true, encoding: .utf8)
        try? req.body.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("body.raw")))
        for (file, content) in extra where !content.isEmpty {
            try? content.write(toFile: (dir as NSString).appendingPathComponent(file),
                               atomically: true, encoding: .utf8)
        }
        return dir
    }
}

func escapeXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
