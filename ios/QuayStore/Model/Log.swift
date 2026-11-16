import Foundation

/// One log file for the core (Rust tracing writes into it) and the app.
enum Log {
    static let url = Paths.caches.appendingPathComponent("quay.log")

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// The last lines, newest at the bottom.
    static func tail(_ lines: Int = 1500) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    static func clear() { try? Data().write(to: url) }
}
