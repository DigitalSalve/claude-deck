import Foundation

/// Plain-file debug log (`~/.claude/claudedeck-debug.log`), used while
/// diagnosing scheduling. Cheap, append-only, capped by truncation at 1 MB.
package enum DebugLog {
    package static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedeck-debug.log")
    private static let lock = NSLock()
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    /// Off by default. Enable with `defaults write io.github.digitalsalve.claudedeck debugLog -bool true`
    /// or the CLAUDEDECK_DEBUG=1 environment variable.
    package static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["CLAUDEDECK_DEBUG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "debugLog")
    }()

    package static func write(_ msg: String) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
