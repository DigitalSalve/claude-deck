import Foundation

/// ClaudeDeck's Claude Code status line (`claudedeck statusline`).
///
/// Claude Code runs the status line command after each message and pipes it a
/// JSON document that includes the account's `rate_limits`. This command does
/// two jobs with it:
/// 1. Saves the document to `~/.claude/claudedeck-usage.json`, which is where
///    the app's live 5-hour / weekly bars come from (`UsageWindows`).
/// 2. Prints the line: `{model} · {cwd} · {tokens}/turn · {waste}x`, where
///    waste is the latest turn's input context over the first turn's.
package enum StatusLine {

    /// Writes the status line input to `url` atomically, but only when it
    /// carries usable `rate_limits`, so an API-key session (which has none)
    /// cannot blank the last good numbers. Returns true when written.
    @discardableResult
    package static func saveUsage(_ input: Data, to url: URL = UsageWindows.defaultURL) -> Bool {
        guard UsageWindows.parse(input, updatedAt: Date()) != nil else { return false }
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: input,
                                             attributes: [.posixPermissions: 0o600])
        else { return false }
        if rename(tmp.path, url.path) != 0 {
            unlink(tmp.path)
            return false
        }
        return true
    }

    /// The printed line. Never throws: unreadable input gives an empty line.
    package static func render(_ input: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return "" }
        let model = json["model"] as? [String: Any]
        let name = (model?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (model?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "claude"
        let cwd = (json["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.currentDirectoryPath
        var trimmed = cwd
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        let base = (trimmed as NSString).lastPathComponent
        let cwdShort = base.isEmpty ? cwd : base

        var line = "\(name) · \(cwdShort)"
        if let path = json["transcript_path"] as? String, !path.isEmpty,
           let w = contextWaste(transcript: URL(fileURLWithPath: path)) {
            line += " · \(formatTokens(w.last))/turn · \(String(format: "%.1f", w.ratio))x\(wasteMarker(w.ratio))"
        }
        return line
    }

    package static func wasteMarker(_ ratio: Double) -> String {
        if ratio >= 5 { return " 🔴" }
        if ratio >= 3 { return " 🟠" }
        if ratio >= 2 { return " 🟡" }
        return ""
    }

    package static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1e3) }
        return "\(n)"
    }

    /// Input context of the first and latest assistant turns that report
    /// usage. Reads the transcript from the front until the first turn and
    /// from the back until the latest, so a long transcript costs two small
    /// reads instead of a full parse on every status line refresh.
    package static func contextWaste(transcript: URL) -> (first: Int, last: Int, ratio: Double)? {
        guard let fh = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? fh.close() }
        guard let first = scan(fh, fromEnd: false), first > 0,
              let last = scan(fh, fromEnd: true)
        else { return nil }
        return (first, last, Double(last) / Double(first))
    }

    /// Input tokens of one transcript line, or nil when the line is not an
    /// assistant turn with usage (a turn with zero input and output counts as none).
    package static func turnInput(_ line: Data) -> Int? {
        // Cheap pre-filter: most lines (tool results, user turns) have no usage.
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
        else { return nil }
        func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        let input = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
        if input == 0 && n("output_tokens") == 0 { return nil }
        return input
    }

    private static let chunk = 256 * 1024
    private static let maxScan: UInt64 = 64 * 1024 * 1024

    private static func scan(_ fh: FileHandle, fromEnd: Bool) -> Int? {
        let newline = UInt8(ascii: "\n")
        guard let size = try? fh.seekToEnd() else { return nil }
        if !fromEnd {
            try? fh.seek(toOffset: 0)
            var buffer = Data()
            var read: UInt64 = 0
            while read < min(size, maxScan) {
                guard let data = try? fh.read(upToCount: chunk), !data.isEmpty else { break }
                read += UInt64(data.count)
                buffer.append(data)
                while let nl = buffer.firstIndex(of: newline) {
                    let line = buffer[buffer.startIndex..<nl]
                    if let v = turnInput(Data(line)) { return v }
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
            }
            return buffer.isEmpty ? nil : turnInput(buffer)
        }
        var offset = size
        var buffer = Data()   // bytes from `offset` to the start of the last line already checked
        while offset > 0 && size - offset < maxScan {
            let step = min(UInt64(chunk), offset)
            offset -= step
            try? fh.seek(toOffset: offset)
            guard let data = try? fh.read(upToCount: Int(step)) else { return nil }
            buffer = data + buffer
            // Every line after the first newline is complete; at offset 0 the first is too.
            while let nl = buffer.lastIndex(of: newline) {
                let line = buffer[buffer.index(after: nl)..<buffer.endIndex]
                if !line.isEmpty, let v = turnInput(Data(line)) { return v }
                buffer.removeSubrange(nl..<buffer.endIndex)
            }
            if offset == 0, !buffer.isEmpty { return turnInput(buffer) }
        }
        return nil
    }
}

/// Points Claude Code's `statusLine` setting in `~/.claude/settings.json` at
/// `claudedeck statusline`. Edits only the `statusLine` entry's text, so the
/// rest of the file keeps its order and formatting, and validates the result
/// before it is written.
package enum StatusLineSetup {

    package enum State: Equatable {
        case notSet
        /// Ours; `then` is the user's own status line command it chains to, if any.
        case installed(then: String?)
        case other(command: String)
        /// A statusLine entry with no command string (unexpected shape).
        case unrecognised
    }

    package enum Change: Equatable {
        case unchanged
        case installed
        case wrapped(previous: String)
        case replaced(previous: String)
        case restored(command: String)
        case removed
    }

    package enum SetupError: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case notAnObject
        case unrecognised
        case notInstalled
        case invalidResult

        package var description: String {
            switch self {
            case .unreadable(let why): return "cannot read settings.json: \(why)"
            case .notAnObject: return "settings.json is not a JSON object"
            case .unrecognised: return "settings.json has a statusLine entry without a command; edit it by hand"
            case .notInstalled: return "the ClaudeDeck status line is not installed"
            case .invalidResult: return "the edited settings.json did not validate; nothing was written"
            }
        }
    }

    package static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    package static var defaultCLIPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/bin/claudedeck").path
    }

    /// POSIX single-quoting for a value placed in a shell command line.
    package static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Reverses `shellQuote` for a string that is exactly one quoted word.
    package static func shellUnquote(_ s: String) -> String? {
        guard s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") else { return nil }
        let inner = String(s.dropFirst().dropLast())
        // Any bare ' inside must be part of the '\'' escape.
        let restored = inner.replacingOccurrences(of: "'\\''", with: "'")
        guard shellQuote(restored) == s else { return nil }
        return restored
    }

    package static func command(cli: String, then: String?) -> String {
        var cmd = "\(shellQuote(cli)) statusline"
        if let then { cmd += " --then \(shellQuote(then))" }
        return cmd
    }

    package static func isOurs(_ command: String) -> Bool {
        command.range(of: #"claudedeck'? statusline(\s|$)"#, options: .regularExpression) != nil
    }

    package static func state(of text: String) -> State {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json["statusLine"]
        else { return .notSet }
        guard let cmd = (entry as? [String: Any])?["command"] as? String else { return .unrecognised }
        guard isOurs(cmd) else { return .other(command: cmd) }
        if let r = cmd.range(of: " --then ") {
            return .installed(then: shellUnquote(String(cmd[r.upperBound...])))
        }
        return .installed(then: nil)
    }

    /// Current state of the real settings file.
    package static func currentState() -> State {
        guard let text = try? String(contentsOf: settingsURL.resolvingSymlinksInPath(), encoding: .utf8) else { return .notSet }
        return state(of: text)
    }

    /// Install into settings text. An existing status line of the user's is
    /// kept and chained (`--then`) unless `replace` is set.
    package static func install(_ text: String, cli: String, replace: Bool) throws -> (text: String, change: Change) {
        let current = try topLevel(text)
        switch state(of: text) {
        case .installed(let then?) where replace:
            // Chained to the user's line; --replace switches to ClaudeDeck's own line.
            return (try replaceCommand(text, scan: current, command: command(cli: cli, then: nil)), .replaced(previous: then))
        case .installed: return (text, .unchanged)
        case .unrecognised: throw SetupError.unrecognised
        case .notSet:
            let entry: [String: Any] = ["type": "command", "command": command(cli: cli, then: nil)]
            return (try insertKey(text, scan: current, value: entry), .installed)
        case .other(let previous):
            let newCommand = command(cli: cli, then: replace ? nil : previous)
            let out = try replaceCommand(text, scan: current, command: newCommand)
            return (out, replace ? .replaced(previous: previous) : .wrapped(previous: previous))
        }
    }

    /// Undo `install`: restore a chained command, or remove the entry.
    package static func uninstall(_ text: String) throws -> (text: String, change: Change) {
        let current = try topLevel(text)
        guard case .installed(let then) = state(of: text) else { throw SetupError.notInstalled }
        if let then {
            return (try replaceCommand(text, scan: current, command: then), .restored(command: then))
        }
        return (try removeKey(text, scan: current), .removed)
    }

    /// Applies `edit` to the real settings file: backs it up, writes it
    /// atomically (through a symlink to its target), and returns the change
    /// and the backup path. Writes nothing when unchanged.
    package static func apply(at url: URL = settingsURL,
                              _ edit: (String) throws -> (text: String, change: Change)) throws -> (change: Change, backup: URL?) {
        let target = url.resolvingSymlinksInPath()
        let original: String
        if FileManager.default.fileExists(atPath: target.path) {
            do { original = try String(contentsOf: target, encoding: .utf8) }
            catch { throw SetupError.unreadable(error.localizedDescription) }
        } else {
            original = "{}\n"
        }
        let (text, change) = try edit(original)
        guard change != .unchanged, text != original else { return (.unchanged, nil) }
        var backup: URL? = nil
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let b = target.deletingLastPathComponent().appendingPathComponent("settings.json.bak-claudedeck-\(stamp)")
            try FileManager.default.copyItem(at: target, to: b)
            backup = b
        } else {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(text.utf8).write(to: target, options: .atomic)
        return (change, backup)
    }

    // MARK: - Text-span editing

    /// Positions in the settings text, in UTF-8 byte offsets.
    package struct Scan {
        let open: Int            // index of the top-level `{`
        let close: Int           // index of the top-level `}`
        let firstKey: Int?       // index of the first key's opening quote
        let keyStart: Int?       // `"statusLine"` opening quote
        let valueStart: Int?
        let valueEnd: Int?       // one past the value
    }

    private static func topLevel(_ text: String) throws -> Scan {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else { throw SetupError.notAnObject }
        let b = Array(text.utf8)
        var i = skipSpace(b, 0)
        guard i < b.count, b[i] == UInt8(ascii: "{") else { throw SetupError.notAnObject }
        let open = i
        i += 1
        var firstKey: Int? = nil, keyStart: Int? = nil, valueStart: Int? = nil, valueEnd: Int? = nil
        while true {
            i = skipSpace(b, i)
            guard i < b.count else { throw SetupError.notAnObject }
            if b[i] == UInt8(ascii: "}") { break }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            guard b[i] == UInt8(ascii: "\"") else { throw SetupError.notAnObject }
            let ks = i
            if firstKey == nil { firstKey = ks }
            let ke = skipString(b, i)
            let key = String(decoding: b[(ks + 1)..<(ke - 1)], as: UTF8.self)
            i = skipSpace(b, ke)
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw SetupError.notAnObject }
            i = skipSpace(b, i + 1)
            let vs = i
            i = skipValue(b, i)
            if key == "statusLine" { keyStart = ks; valueStart = vs; valueEnd = i }
        }
        return Scan(open: open, close: i, firstKey: firstKey, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd)
    }

    private static func skipSpace(_ b: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
        return i
    }

    /// `start` is at an opening quote; returns one past the closing quote.
    private static func skipString(_ b: [UInt8], _ start: Int) -> Int {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return b.count
    }

    private static func skipValue(_ b: [UInt8], _ start: Int) -> Int {
        guard start < b.count else { return start }
        let c = b[start]
        if c == UInt8(ascii: "\"") { return skipString(b, start) }
        if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
            var depth = 0
            var i = start
            while i < b.count {
                let ch = b[i]
                if ch == UInt8(ascii: "\"") { i = skipString(b, i); continue }
                if ch == UInt8(ascii: "{") || ch == UInt8(ascii: "[") { depth += 1 }
                if ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return b.count
        }
        var i = start
        while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
        return i
    }

    /// Indentation of the line holding byte `index`.
    private static func indent(_ b: [UInt8], at index: Int) -> String {
        var s = index
        while s > 0, b[s - 1] != 0x0A { s -= 1 }
        var e = s
        while e < b.count, b[e] == 0x20 || b[e] == 0x09 { e += 1 }
        return String(decoding: b[s..<e], as: UTF8.self)
    }

    private static func jsonFragment(_ value: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys])
        else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    /// `{ "type": ..., "command": ..., <others sorted> }` laid out like the file.
    private static func renderEntry(_ entry: [String: Any], keyIndent: String) -> String {
        let unit = keyIndent.isEmpty ? "  " : (keyIndent.hasPrefix("\t") ? "\t" : String(repeating: " ", count: min(keyIndent.count, 4)))
        let inner = keyIndent + unit
        let order = ["type", "command"].filter { entry[$0] != nil } + entry.keys.filter { $0 != "type" && $0 != "command" }.sorted()
        let lines = order.map { "\(inner)\(jsonFragment($0)): \(jsonFragment(entry[$0]!))" }
        return "{\n" + lines.joined(separator: ",\n") + "\n\(keyIndent)}"
    }

    private static func splice(_ b: [UInt8], _ range: Range<Int>, _ with: String) -> String {
        var out = b
        out.replaceSubrange(range, with: Array(with.utf8))
        return String(decoding: out, as: UTF8.self)
    }

    private static func validated(_ text: String, expect: (Any?) -> Bool) throws -> String {
        guard let d = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              expect(json["statusLine"])
        else { throw SetupError.invalidResult }
        return text
    }

    private static func insertKey(_ text: String, scan: Scan, value: [String: Any]) throws -> String {
        let b = Array(text.utf8)
        let keyIndent = scan.firstKey.map { indent(b, at: $0) } ?? "  "
        let entry = "\"statusLine\": " + renderEntry(value, keyIndent: keyIndent)
        let out: String
        if let first = scan.firstKey {
            // Insert before the first key, on its own line with the same indent.
            out = splice(b, first..<first, entry + ",\n" + keyIndent)
        } else {
            out = splice(b, (scan.open + 1)..<scan.close, "\n" + keyIndent + entry + "\n")
        }
        let cmd = value["command"] as? String
        return try validated(out) { ($0 as? [String: Any])?["command"] as? String == cmd }
    }

    private static func replaceCommand(_ text: String, scan: Scan, command: String) throws -> String {
        guard let ks = scan.keyStart, let vs = scan.valueStart, let ve = scan.valueEnd else { throw SetupError.notInstalled }
        let b = Array(text.utf8)
        guard let d = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var entry = json["statusLine"] as? [String: Any]
        else { throw SetupError.unrecognised }
        entry["command"] = command
        if entry["type"] == nil { entry["type"] = "command" }
        let out = splice(b, vs..<ve, renderEntry(entry, keyIndent: indent(b, at: ks)))
        return try validated(out) { ($0 as? [String: Any])?["command"] as? String == command }
    }

    private static func removeKey(_ text: String, scan: Scan) throws -> String {
        guard let ks = scan.keyStart, let ve = scan.valueEnd else { throw SetupError.notInstalled }
        let b = Array(text.utf8)
        var start = ks, end = ve
        let after = skipSpace(b, ve)
        if after < b.count, b[after] == UInt8(ascii: ",") {
            // Drop through the comma and the whitespace up to the next key.
            end = skipSpace(b, after + 1)
            // Keep the next key's indentation: back up to the start of its line.
            var lineStart = end
            while lineStart > after + 1, b[lineStart - 1] != 0x0A { lineStart -= 1 }
            if lineStart > after + 1 { end = lineStart }
            // Remove the removed key's own indentation too.
            while start > 0, b[start - 1] == 0x20 || b[start - 1] == 0x09 { start -= 1 }
        } else {
            // Last key: drop the comma before it instead.
            var p = ks
            while p > 0, [0x20, 0x09, 0x0A, 0x0D].contains(b[p - 1]) { p -= 1 }
            if p > 0, b[p - 1] == UInt8(ascii: ",") { start = p - 1 }
        }
        let out = splice(b, start..<end, "")
        return try validated(out) { $0 == nil }
    }
}
