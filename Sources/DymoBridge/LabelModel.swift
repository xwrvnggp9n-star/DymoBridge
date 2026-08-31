import Foundation

// Model of the DLS "DieCutLabel" XML that the DYMO JS framework POSTs.
// All geometry is in twips (1/1440 inch). Object Bounds are in the label's
// display orientation (i.e. already rotated when PaperOrientation=Landscape),
// while the DrawCommands die-cut rect is portrait width x height.

enum HAlign: String { case left = "Left", center = "Center", right = "Right" }
enum VAlign: String { case top = "Top", middle = "Middle", bottom = "Bottom" }
enum FitMode: String { case none = "None", shrink = "ShrinkToFit", always = "AlwaysFit" }

struct StyledRun {
    var text: String
    var fontFamily: String
    var fontSize: Double     // points
    var bold: Bool
    var italic: Bool
    var underline: Bool
}

struct LabelObject {
    enum Kind {
        case text(runs: [StyledRun], hAlign: HAlign, vAlign: VAlign, fit: FitMode)
        case barcode(text: String, type: String, showText: Bool)
        case image(base64: String)
        case shape(kind: String)   // HorizontalLine, VerticalLine, Rectangle...
    }
    var name: String
    var kind: Kind
    var bounds: CGRect           // twips, top-left origin, display orientation
    var rotation: Int            // degrees: 0/90/180/270
}

struct Label {
    var paperName: String
    var isLandscape: Bool
    var dieCutWidthTwips: Double    // portrait: across feed
    var dieCutHeightTwips: Double   // portrait: label length
    var objects: [LabelObject]

    // Canvas in display orientation.
    var canvasWidthTwips: Double  { isLandscape ? dieCutHeightTwips : dieCutWidthTwips }
    var canvasHeightTwips: Double { isLandscape ? dieCutWidthTwips : dieCutHeightTwips }
}

// One printed label = the template with ObjectData substitutions applied.
struct LabelRecord {
    var values: [String: String]   // object name -> replacement text/base64
}

enum LabelParseError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        if case .invalid(let m) = self { return "label parse error: \(m)" }
        return "label parse error"
    }
}

enum LabelParser {

    static func parseLabel(xml: String) throws -> Label {
        let doc = try XMLDocument(xmlString: xml, options: [.documentTidyXML])
        guard let root = doc.rootElement() else { throw LabelParseError.invalid("no root") }
        let rootName = root.name ?? ""
        guard rootName == "DieCutLabel" || rootName == "ContinuousLabel" else {
            throw LabelParseError.invalid("unsupported root <\(rootName)> (expected DieCutLabel)")
        }

        let paperName = text(root, "PaperName") ?? "30252 Address"
        let isLandscape = (text(root, "PaperOrientation") ?? "Landscape") == "Landscape"

        // Die-cut outline: first Rectangle/RoundRectangle under DrawCommands.
        var w = 0.0, h = 0.0
        if let draw = root.elements(forName: "DrawCommands").first {
            for child in draw.children ?? [] {
                guard let el = child as? XMLElement,
                      el.name == "RoundRectangle" || el.name == "Rectangle" else { continue }
                w = attr(el, "Width") ?? 0
                h = attr(el, "Height") ?? 0
                break
            }
        }
        if w <= 0 || h <= 0 { w = 1581; h = 5040 }   // default to 30252 Address

        var objects: [LabelObject] = []
        for info in root.elements(forName: "ObjectInfo") {
            guard let boundsEl = info.elements(forName: "Bounds").first else { continue }
            let bounds = CGRect(x: attr(boundsEl, "X") ?? 0, y: attr(boundsEl, "Y") ?? 0,
                                width: attr(boundsEl, "Width") ?? 0, height: attr(boundsEl, "Height") ?? 0)
            for child in info.children ?? [] {
                guard let el = child as? XMLElement, let elName = el.name, elName != "Bounds" else { continue }
                if let obj = parseObject(el, elName: elName, bounds: bounds) {
                    objects.append(obj)
                }
            }
        }

        return Label(paperName: paperName, isLandscape: isLandscape,
                     dieCutWidthTwips: min(w, h), dieCutHeightTwips: max(w, h),
                     objects: objects)
    }

    private static func parseObject(_ el: XMLElement, elName: String, bounds: CGRect) -> LabelObject? {
        let name = text(el, "Name") ?? elName
        let rotation: Int
        switch text(el, "Rotation") ?? "Rotation0" {
        case "Rotation90": rotation = 90
        case "Rotation180": rotation = 180
        case "Rotation270": rotation = 270
        default: rotation = 0
        }

        switch elName {
        case "TextObject", "AddressObject":
            var runs: [StyledRun] = []
            if let styled = el.elements(forName: "StyledText").first {
                for element in styled.elements(forName: "Element") {
                    let str = text(element, "String") ?? ""
                    var family = "Helvetica", size = 12.0, bold = false, italic = false, underline = false
                    if let attrs = element.elements(forName: "Attributes").first,
                       let font = attrs.elements(forName: "Font").first {
                        family = font.attribute(forName: "Family")?.stringValue ?? family
                        size = Double(font.attribute(forName: "Size")?.stringValue ?? "") ?? size
                        bold = font.attribute(forName: "Bold")?.stringValue == "True"
                        italic = font.attribute(forName: "Italic")?.stringValue == "True"
                        underline = font.attribute(forName: "Underline")?.stringValue == "True"
                    }
                    runs.append(StyledRun(text: str, fontFamily: family, fontSize: size,
                                          bold: bold, italic: italic, underline: underline))
                }
            }
            let h = HAlign(rawValue: text(el, "HorizontalAlignment") ?? "") ?? .left
            let v = VAlign(rawValue: text(el, "VerticalAlignment") ?? "") ?? .middle
            let fit = FitMode(rawValue: text(el, "TextFitMode") ?? "") ?? .shrink
            return LabelObject(name: name, kind: .text(runs: runs, hAlign: h, vAlign: v, fit: fit),
                               bounds: bounds, rotation: rotation)

        case "BarcodeObject":
            let content = text(el, "Text") ?? ""
            let type = text(el, "Type") ?? "Code128Auto"
            let showText = (text(el, "TextPosition") ?? "Bottom") != "None"
            return LabelObject(name: name, kind: .barcode(text: content, type: type, showText: showText),
                               bounds: bounds, rotation: rotation)

        case "ImageObject":
            let b64 = text(el, "Image") ?? ""
            return LabelObject(name: name, kind: .image(base64: b64), bounds: bounds, rotation: rotation)

        case "ShapeObject":
            let kind = text(el, "ShapeType") ?? "Rectangle"
            return LabelObject(name: name, kind: .shape(kind: kind), bounds: bounds, rotation: rotation)

        default:
            Log.info("unsupported object <\(elName)> named '\(name)' — skipped")
            return nil
        }
    }

    static func parseLabelSet(xml: String) -> [LabelRecord] {
        guard let doc = try? XMLDocument(xmlString: xml, options: [.documentTidyXML]),
              let root = doc.rootElement() else { return [] }
        var records: [LabelRecord] = []
        for rec in root.elements(forName: "LabelRecord") {
            var values: [String: String] = [:]
            for od in rec.elements(forName: "ObjectData") {
                if let key = od.attribute(forName: "Name")?.stringValue {
                    values[key] = od.stringValue ?? ""
                }
            }
            records.append(LabelRecord(values: values))
        }
        return records
    }

    struct PrintParams {
        var copies = 1
        var jobTitle = "DymoBridge label"
    }

    static func parsePrintParams(xml: String) -> PrintParams {
        var p = PrintParams()
        guard let doc = try? XMLDocument(xmlString: xml, options: [.documentTidyXML]),
              let root = doc.rootElement() else { return p }
        if let c = text(root, "Copies"), let n = Int(c), n > 0 { p.copies = n }
        if let t = text(root, "JobTitle"), !t.isEmpty { p.jobTitle = t }
        return p
    }

    // MARK: - helpers
    private static func text(_ el: XMLElement, _ name: String) -> String? {
        el.elements(forName: name).first?.stringValue
    }
    private static func attr(_ el: XMLElement, _ name: String) -> Double? {
        Double(el.attribute(forName: name)?.stringValue ?? "")
    }
}
