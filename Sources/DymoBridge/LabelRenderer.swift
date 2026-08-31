import Foundation
import AppKit

// Renders a parsed Label (plus per-record substitutions) to a 300 dpi PNG.
// Everything is drawn in pixel space with a bottom-up CG coordinate system;
// label XML rects are top-left origin, so y gets flipped on conversion.

enum LabelRenderer {

    static let dpi = 300.0
    static let twipsPerInch = 1440.0
    static var pxPerTwip: Double { dpi / twipsPerInch }

    static func render(label: Label, record: LabelRecord?) throws -> Data {
        let widthPx = Int((label.canvasWidthTwips * pxPerTwip).rounded())
        let heightPx = Int((label.canvasHeightTwips * pxPerTwip).rounded())
        guard widthPx > 0, heightPx > 0, widthPx < 6000, heightPx < 6000 else {
            throw LabelParseError.invalid("bad canvas size \(widthPx)x\(heightPx)")
        }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: widthPx, pixelsHigh: heightPx,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw LabelParseError.invalid("could not create bitmap context")
        }
        // Tag as 300 dpi so CUPS scales it to physical size correctly.
        rep.size = NSSize(width: Double(widthPx) * 72.0 / dpi, height: Double(heightPx) * 72.0 / dpi)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let cg = gctx.cgContext
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        for object in label.objects {
            let px = pxRect(object.bounds, canvasHeightPx: Double(heightPx))
            // For 90/270 rotations the Bounds describe the on-label footprint;
            // content lays out in a width/height-swapped rect that shares the
            // same center, then rotates into the footprint.
            var contentRect = px
            if object.rotation == 90 || object.rotation == 270 {
                contentRect = CGRect(x: px.midX - px.height / 2, y: px.midY - px.width / 2,
                                     width: px.height, height: px.width)
            }
            cg.saveGState()
            if object.rotation != 0 {
                // Rotation direction chosen so the printed output (which is
                // fed 180°-rotated) reads the way the vendor's physical labels
                // do — verified against a real vendor-printed tag.
                cg.translateBy(x: px.midX, y: px.midY)
                cg.rotate(by: CGFloat(object.rotation) * .pi / 180)
                cg.translateBy(x: -px.midX, y: -px.midY)
            }
            draw(object, in: contentRect, record: record, cg: cg)
            cg.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw LabelParseError.invalid("PNG encode failed")
        }
        return png
    }

    // Rotate a rendered PNG 180° for printing: the vendor's print path feeds
    // labels this way, so matching keeps the physical output orientation
    // (tear-off edge, peel direction) identical to what staff are used to.
    static func rotate180(png: Data) throws -> Data {
        guard let src = NSBitmapImageRep(data: png), let cgImage = src.cgImage else {
            throw LabelParseError.invalid("rotate180: could not decode PNG")
        }
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LabelParseError.invalid("rotate180: context failed")
        }
        ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
        ctx.rotate(by: .pi)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rotated = ctx.makeImage() else {
            throw LabelParseError.invalid("rotate180: render failed")
        }
        let rep = NSBitmapImageRep(cgImage: rotated)
        rep.size = src.size   // preserve the 300 dpi physical-size tag for CUPS
        guard let out = rep.representation(using: .png, properties: [:]) else {
            throw LabelParseError.invalid("rotate180: PNG encode failed")
        }
        return out
    }

    // twips top-left rect -> pixel bottom-up rect
    private static func pxRect(_ r: CGRect, canvasHeightPx: Double) -> CGRect {
        let s = pxPerTwip
        return CGRect(x: r.minX * s,
                      y: canvasHeightPx - (r.minY + r.height) * s,
                      width: r.width * s,
                      height: r.height * s)
    }

    private static func draw(_ object: LabelObject, in rect: CGRect, record: LabelRecord?, cg: CGContext) {
        let override = record?.values[object.name]
        switch object.kind {
        case .text(let runs, let hAlign, let vAlign, let fit):
            var effective = runs
            if let value = override {
                // Substituted data keeps the first run's font attributes.
                let proto = runs.first ?? StyledRun(text: "", fontFamily: "Helvetica", fontSize: 12,
                                                   bold: false, italic: false, underline: false)
                effective = [StyledRun(text: value, fontFamily: proto.fontFamily, fontSize: proto.fontSize,
                                       bold: proto.bold, italic: proto.italic, underline: proto.underline)]
            }
            drawText(runs: effective, hAlign: hAlign, vAlign: vAlign, fit: fit, in: rect)

        case .barcode(let text, let type, let showText):
            drawBarcode(text: override ?? text, type: type, showText: showText, in: rect, cg: cg)

        case .image(let base64):
            let b64 = override ?? base64
            if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
               let image = NSImage(data: data) {
                drawAspectFit(image, in: rect)
            }

        case .shape(let kind):
            cg.setFillColor(CGColor(gray: 0, alpha: 1))
            cg.setStrokeColor(CGColor(gray: 0, alpha: 1))
            let lineWidth = max(2.0, rect.height * 0.02)
            switch kind {
            case "HorizontalLine":
                cg.fill(CGRect(x: rect.minX, y: rect.midY - lineWidth / 2, width: rect.width, height: lineWidth))
            case "VerticalLine":
                cg.fill(CGRect(x: rect.midX - lineWidth / 2, y: rect.minY, width: lineWidth, height: rect.height))
            case "Ellipse":
                cg.strokeEllipse(in: rect.insetBy(dx: lineWidth, dy: lineWidth))
            default:
                cg.stroke(rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), width: lineWidth)
            }
        }
    }

    // MARK: - text

    private static func font(for run: StyledRun, scale: Double) -> NSFont {
        let sizePx = run.fontSize * dpi / 72.0 * scale
        var f = NSFont(name: run.fontFamily, size: sizePx) ?? NSFont.systemFont(ofSize: sizePx)
        let fm = NSFontManager.shared
        if run.bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if run.italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    private static func attributed(runs: [StyledRun], hAlign: HAlign, scale: Double) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        switch hAlign {
        case .left: para.alignment = .left
        case .center: para.alignment = .center
        case .right: para.alignment = .right
        }
        para.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString()
        for run in runs {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font(for: run, scale: scale),
                .foregroundColor: NSColor.black,
                .paragraphStyle: para,
            ]
            if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return out
    }

    private static func measure(_ s: NSAttributedString, wrapWidth: CGFloat?) -> CGRect {
        s.boundingRect(with: NSSize(width: wrapWidth ?? .greatestFiniteMagnitude,
                                    height: .greatestFiniteMagnitude),
                       options: [.usesLineFragmentOrigin])
    }

    private static func drawText(runs: [StyledRun], hAlign: HAlign, vAlign: VAlign, fit: FitMode, in rect: CGRect) {
        guard runs.contains(where: { !$0.text.isEmpty }) else { return }
        let fullText = runs.map(\.text).joined()
        let isSingleLine = !fullText.contains("\n") && !fullText.contains("\r")

        var scale = 1.0
        var str = attributed(runs: runs, hAlign: hAlign, scale: scale)
        var measured: CGRect
        var useWrapping = !isSingleLine

        if isSingleLine {
            // Single-line source (IDs, field captions, signature rules) never
            // word-wraps: a wrapped specimen ID or a stray underscore row
            // bleeding into the neighbor below is worse than smaller type.
            // Height semantics match DLS (verified against the vendor
            // renderer's output for the same XML): the box height bounds the
            // glyphs' CAP height, not the full line height — descenders hang
            // below the box. Width overflow shrinks further.
            measured = measure(str, wrapWidth: nil)
            let baseFont = font(for: runs[0], scale: 1.0)
            let capHeight = baseFont.capHeight
            let widthScale = measured.width > rect.width ? rect.width / measured.width : 1.0
            let heightScale = capHeight > rect.height ? rect.height / capHeight : 1.0
            scale = min(widthScale, heightScale) * 0.98
            if scale < 0.98 {
                str = attributed(runs: runs, hAlign: hAlign, scale: scale)
                measured = measure(str, wrapWidth: nil)
                while measured.width > rect.width, scale > 0.1 {
                    scale *= 0.97
                    str = attributed(runs: runs, hAlign: hAlign, scale: scale)
                    measured = measure(str, wrapWidth: nil)
                }
            } else {
                scale = 1.0
            }
        } else {
            measured = measure(str, wrapWidth: rect.width)
        }

        if useWrapping {
            measured = measure(str, wrapWidth: rect.width)
            if fit != .none {
                var attempts = 0
                while (measured.height > rect.height || measured.width > rect.width),
                      scale > 0.15, attempts < 40 {
                    scale *= 0.92
                    attempts += 1
                    str = attributed(runs: runs, hAlign: hAlign, scale: scale)
                    measured = measure(str, wrapWidth: rect.width)
                }
            }
        }

        // Glyphs may complete past a too-short box (a 12pt "DOB" in a
        // cap-height box), but overflow is capped at whole-line boundaries so
        // extra lines never bleed into neighboring objects.
        let probe = NSAttributedString(string: "Ag", attributes: [.font: font(for: runs[0], scale: scale)])
        let oneLine = measure(probe, wrapWidth: nil).height
        let wholeLines = max(1.0, (rect.height / max(oneLine, 1)).rounded(.down))
        let textHeight = min(measured.height, wholeLines * oneLine)

        // Cap-height anchoring: when the box bounds cap height, the glyph line
        // extends above the box top by (ascender - capHeight); shift up so the
        // caps sit exactly at the box top and descenders hang below.
        var capAdjust: CGFloat = 0
        if isSingleLine && !useWrapping {
            let f = font(for: runs[0], scale: scale)
            capAdjust = max(0, f.ascender - f.capHeight)
        }

        var target = rect
        // NSString drawing lays text from the top of the given rect (it manages
        // its own flip), so adjust the rect's top edge for vertical alignment.
        switch vAlign {
        case .top:
            target = CGRect(x: rect.minX, y: rect.maxY - textHeight + capAdjust,
                            width: rect.width, height: textHeight)
        case .middle:
            target = CGRect(x: rect.minX, y: rect.minY + (rect.height - textHeight) / 2,
                            width: rect.width, height: textHeight)
        case .bottom:
            target = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: textHeight)
        }
        // A hair of slack so rounding never re-wraps a fitted single line.
        if isSingleLine && !useWrapping {
            target.size.width = max(target.width, measured.width + 1)
        }
        str.draw(with: target, options: [.usesLineFragmentOrigin])
    }

    // MARK: - barcode

    private static func drawBarcode(text: String, type: String, showText: Bool, in rect: CGRect, cg: CGContext) {
        guard !text.isEmpty else { return }
        guard let symbol = Barcode.generate(text: text, type: type) else {
            Log.error("barcode generation failed for type=\(type)")
            return
        }
        var barRect = rect
        var textRect = CGRect.zero
        if showText && !Barcode.isSquareSymbology(type) {
            let textHeight = min(rect.height * 0.25, 12.0 * dpi / 72.0)
            barRect = CGRect(x: rect.minX, y: rect.minY + textHeight,
                             width: rect.width, height: rect.height - textHeight)
            textRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: textHeight)
        }
        cg.saveGState()
        cg.interpolationQuality = .none
        if Barcode.isSquareSymbology(type) {
            // Keep 2D codes square, centered.
            let side = min(barRect.width, barRect.height)
            let square = CGRect(x: barRect.midX - side / 2, y: barRect.midY - side / 2, width: side, height: side)
            cg.draw(symbol, in: square)
        } else {
            // Match DLS: bars at the largest integral module multiple that
            // fits the box, centered — never stretched edge to edge. Crisp
            // modules and vendor-like proportions.
            let naturalWidth = CGFloat(symbol.width)
            let moduleScale = max(1, (barRect.width / naturalWidth).rounded(.down))
            let drawWidth = min(naturalWidth * moduleScale, barRect.width)
            let drawRect = CGRect(x: barRect.midX - drawWidth / 2, y: barRect.minY,
                                  width: drawWidth, height: barRect.height)
            cg.draw(symbol, in: drawRect)
        }
        cg.restoreGState()

        if showText && !Barcode.isSquareSymbology(type) {
            let run = StyledRun(text: text, fontFamily: "Helvetica", fontSize: 8,
                                bold: false, italic: false, underline: false)
            drawText(runs: [run], hAlign: .center, vAlign: .middle, fit: .shrink, in: textRect)
        }
    }

    private static func drawAspectFit(_ image: NSImage, in rect: CGRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
        let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        image.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}
