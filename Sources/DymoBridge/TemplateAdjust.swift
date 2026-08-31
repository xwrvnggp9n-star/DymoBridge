import Foundation

// Site-specific adjustments to label templates, applied after parsing.
// The template arrives inside every print request, so local layout
// preferences have to live bridge-side. Rules load from a JSON file:
// --adjust PATH, or /usr/local/etc/dymo-bridge/adjust.json when present;
// --no-adjust disables. With no file, labels render exactly as sent.
//
// Schema (coordinates in twips, top-left origin, matching the DLS XML):
// { "rules": [ { "comment": "...",
//                "trigger": { "objectExists": "NAME" },
//                "remove": ["NAME", ...],
//                "objects": { "NAME": { "x":n, "y":n, "w":n, "h":n,
//                                       "fontScale":n } } } ] }
// See examples/kipu-specimen-adjust.json.

struct AdjustRules: Codable {
    struct Rule: Codable {
        struct Trigger: Codable { var objectExists: String }
        struct Placement: Codable {
            var x: Double?
            var y: Double?
            var w: Double?
            var h: Double?
            var fontScale: Double?
        }
        var comment: String?
        var trigger: Trigger
        var remove: [String]?
        var objects: [String: Placement]?
    }
    var rules: [Rule]
}

enum TemplateAdjust {

    private(set) static var rules: AdjustRules?

    static func load(path: String) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoded = try JSONDecoder().decode(AdjustRules.self, from: data)
            rules = decoded
            Log.info("template adjustments loaded: \(decoded.rules.count) rule(s) from \(path)")
        } catch {
            Log.error("could not load template adjustments from \(path): \(error) — continuing without")
        }
    }

    static func apply(_ label: inout Label) {
        guard let ruleSet = rules else { return }
        for rule in ruleSet.rules {
            guard label.objects.contains(where: { $0.name == rule.trigger.objectExists }) else { continue }
            let removeSet = Set(rule.remove ?? [])
            var out: [LabelObject] = []
            for var obj in label.objects {
                if removeSet.contains(obj.name) { continue }
                if let p = rule.objects?[obj.name] {
                    if let x = p.x { obj.bounds.origin.x = x }
                    if let y = p.y { obj.bounds.origin.y = y }
                    if let w = p.w { obj.bounds.size.width = w }
                    if let h = p.h { obj.bounds.size.height = h }
                    if let scale = p.fontScale,
                       case .text(let runs, let hA, let vA, let fit) = obj.kind {
                        let scaled = runs.map { run -> StyledRun in
                            var r = run
                            r.fontSize *= scale
                            return r
                        }
                        obj.kind = .text(runs: scaled, hAlign: hA, vAlign: vA, fit: fit)
                    }
                }
                out.append(obj)
            }
            label.objects = out
            Log.info("template rule applied (trigger: \(rule.trigger.objectExists))")
        }
    }
}
