import Foundation

enum Log {
    private static var logFile: FileHandle?
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let queue = DispatchQueue(label: "dymo-bridge.log")

    static func setup(dir: String) {
        let path = (dir as NSString).appendingPathComponent("dymo-bridge.log")
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        logFile = FileHandle(forWritingAtPath: path)
        logFile?.seekToEndOfFile()
    }

    static func info(_ msg: String)  { write("INFO", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }

    private static func write(_ level: String, _ msg: String) {
        let line = "\(fmt.string(from: Date())) [\(level)] \(msg)\n"
        queue.sync {
            FileHandle.standardError.write(Data(line.utf8))
            logFile?.write(Data(line.utf8))
        }
    }
}
