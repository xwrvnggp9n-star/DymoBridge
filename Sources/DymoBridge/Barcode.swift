import Foundation
import CoreImage
import CoreGraphics

// Barcode generation. Code 128 / QR come from CoreImage's built-in generators;
// Code 39 is generated from the standard pattern table (CoreImage has none).

enum Barcode {

    // Returns a 1x-scale CGImage of the barcode (no quiet zone padding beyond
    // what the generator emits). Caller scales it into the target bounds with
    // interpolation disabled so modules stay crisp.
    static func generate(text: String, type: String) -> CGImage? {
        let t = type.lowercased()
        if t.hasPrefix("code128") {
            return ciBarcode(filter: "CICode128BarcodeGenerator", key: "inputMessage",
                             value: text.data(using: .ascii) ?? Data())
        }
        if t.hasPrefix("qr") {
            return ciBarcode(filter: "CIQRCodeGenerator", key: "inputMessage",
                             value: text.data(using: .utf8) ?? Data())
        }
        if t.hasPrefix("code39") {
            return code39(text: text)
        }
        if t.hasPrefix("pdf417") {
            return ciBarcode(filter: "CIPDF417BarcodeGenerator", key: "inputMessage",
                             value: text.data(using: .ascii) ?? Data())
        }
        Log.error("unsupported barcode type '\(type)' — falling back to Code 128")
        return ciBarcode(filter: "CICode128BarcodeGenerator", key: "inputMessage",
                         value: text.data(using: .ascii) ?? Data())
    }

    static func isSquareSymbology(_ type: String) -> Bool {
        let t = type.lowercased()
        return t.hasPrefix("qr") || t.hasPrefix("aztec") || t.hasPrefix("datamatrix")
    }

    private static func ciBarcode(filter: String, key: String, value: Data) -> CGImage? {
        guard let f = CIFilter(name: filter) else { return nil }
        f.setValue(value, forKey: key)
        if filter == "CICode128BarcodeGenerator" { f.setValue(0.0, forKey: "inputQuietSpace") }
        guard let output = f.outputImage else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        return ctx.createCGImage(output, from: output.extent)
    }

    // Code 39: 9 elements per char (5 bars, 4 spaces), 3 wide. '1' = wide.
    // Standard table, interleaved bar/space starting with a bar.
    private static let code39Table: [Character: String] = [
        "0": "000110100", "1": "100100001", "2": "001100001", "3": "101100000",
        "4": "000110001", "5": "100110000", "6": "001110000", "7": "000100101",
        "8": "100100100", "9": "001100100",
        "A": "100001001", "B": "001001001", "C": "101001000", "D": "000011001",
        "E": "100011000", "F": "001011000", "G": "000001101", "H": "100001100",
        "I": "001001100", "J": "000011100", "K": "100000011", "L": "001000011",
        "M": "101000010", "N": "000010011", "O": "100010010", "P": "001010010",
        "Q": "000000111", "R": "100000110", "S": "001000110", "T": "000010110",
        "U": "110000001", "V": "011000001", "W": "111000000", "X": "010010001",
        "Y": "110010000", "Z": "011010000",
        "-": "010000101", ".": "110000100", " ": "011000100", "*": "010010100",
        "$": "010101000", "/": "010100010", "+": "010001010", "%": "000101010",
    ]

    private static func code39(text: String) -> CGImage? {
        let wide = 3, narrow = 1, gap = narrow
        let content = "*\(text.uppercased())*"
        var widths: [(width: Int, isBar: Bool)] = []
        for (i, ch) in content.enumerated() {
            guard let pattern = code39Table[ch] else {
                Log.error("Code 39 cannot encode character '\(ch)'")
                return nil
            }
            for (j, bit) in pattern.enumerated() {
                widths.append((bit == "1" ? wide : narrow, j % 2 == 0))
            }
            if i < content.count - 1 { widths.append((gap, false)) }
        }
        let totalWidth = widths.reduce(0) { $0 + $1.width }
        let height = 40

        guard let ctx = CGContext(data: nil, width: totalWidth, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: totalWidth, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        var x = 0
        for seg in widths {
            if seg.isBar {
                ctx.fill(CGRect(x: x, y: 0, width: seg.width, height: height))
            }
            x += seg.width
        }
        return ctx.makeImage()
    }
}
