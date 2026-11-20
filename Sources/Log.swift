import Foundation

/// Opt-in file logging, enabled with `LUMEN_DEBUG=1`.
///
/// Writes to `~/Library/Application Support/Lumen/debug.log` and stays completely
/// silent otherwise, so a normal run leaves no files behind. Useful for the DDC path,
/// where failures are invisible from the outside: `IOAVService` returns either 0 or an
/// IOKit code and nothing else reports what happened.
enum Log {
    static let isEnabled = ProcessInfo.processInfo.environment["LUMEN_DEBUG"] != nil

    private static let url: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("debug.log")
    }()

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(Date().timeIntervalSince1970) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
