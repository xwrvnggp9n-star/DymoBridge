import Foundation

// Site-specific adjustments to Kipu's label templates, applied after parsing.
// The template arrives inside every print request, so local layout preferences
// have to be applied here. Disable with --no-adjust.
//
// Chabad specimen label (identified by its TEXT_SIGNATURE object): the
// signature row is never used — remove it and spread the patient block
// (name / DOB / MR# / test codes) into the freed space with larger type and
// more line spacing.

enum TemplateAdjust {

    static func apply(_ label: inout Label) {
        guard label.objects.contains(where: { $0.name == "TEXT_SIGNATURE" }) else { return }

        // Original rows were 120tw tall on a 150tw pitch at Y=550/700/850,
        // test codes 100tw at Y=970, signature at Y=1159 — freed by its
        // removal. Values (ShrinkToFit) grow with their taller boxes; the
        // fixed-size captions get only a mild font bump, and values shift
        // right so the wider captions don't crowd them.
        struct Row { var x: Double?; var w: Double?; var y: Double; var h: Double; var fontScale: Double? }
        let rows: [String: Row] = [
            "labelFullName":    Row(x: nil, w: nil, y: 540, h: 150, fontScale: nil),
            "TEXT_DOB":         Row(x: nil, w: nil, y: 770, h: 150, fontScale: 1.2),
            "labelDob":         Row(x: 800, w: 1500, y: 770, h: 150, fontScale: nil),
            "TEXT_MR":          Row(x: nil, w: nil, y: 1000, h: 150, fontScale: 1.2),
            "labelMr":          Row(x: 800, w: 1900, y: 1000, h: 150, fontScale: nil),
            "medicalTestCodes": Row(x: nil, w: nil, y: 1190, h: 110, fontScale: nil),
        ]

        var out: [LabelObject] = []
        for var obj in label.objects {
            if obj.name == "TEXT_SIGNATURE" { continue }
            if let row = rows[obj.name] {
                if let x = row.x { obj.bounds.origin.x = x }
                if let w = row.w { obj.bounds.size.width = w }
                obj.bounds.origin.y = row.y
                obj.bounds.size.height = row.h
                if let fontScale = row.fontScale,
                   case .text(let runs, let hA, let vA, let fit) = obj.kind {
                    let scaled = runs.map { run -> StyledRun in
                        var r = run
                        r.fontSize *= fontScale
                        return r
                    }
                    obj.kind = .text(runs: scaled, hAlign: hA, vAlign: vA, fit: fit)
                }
            }
            out.append(obj)
        }
        label.objects = out
        Log.info("template adjustments applied: signature removed, patient block enlarged")
    }
}
