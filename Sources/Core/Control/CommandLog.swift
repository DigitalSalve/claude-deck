import Foundation

/// One line of `~/.claude/claudedeck-commands.log`, as the Commands tab shows it.
/// Reading the file (not `CommandServer.recent`) keeps history across app restarts
/// and includes requests the CLI ran by itself while the app was closed.
package struct CommandLogEntry: Identifiable, Equatable {
    package let id: Int          // line number in the file; stable while the log only grows
    package let at: Date
    package let ok: Bool
    package let verb: String
    package let caller: String?
    package let target: String?
    package let detail: String   // spawn's dir/agent/mode fields; empty for other verbs
    package let message: String

    package init(id: Int, at: Date, ok: Bool, verb: String, caller: String?, target: String?,
                 detail: String, message: String) {
        self.id = id; self.at = at; self.ok = ok; self.verb = verb
        self.caller = caller; self.target = target; self.detail = detail; self.message = message
    }
}

package enum CommandLog {
    package static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedeck-commands.log")

    /// Parses `<ISO8601> ok |ERR <verb> caller=<id|-> target=<id|->[ detail] :: <message>`.
    package static func parse(_ line: String, id: Int) -> CommandLogEntry? {
        let parts = line.components(separatedBy: " :: ")
        guard parts.count >= 2 else { return nil }
        let message = parts.dropFirst().joined(separator: " :: ")
        let head = parts[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard head.count >= 5,
              let at = ISO8601DateFormatter().date(from: head[0]),
              head[1] == "ok" || head[1] == "ERR",
              head[3].hasPrefix("caller="), head[4].hasPrefix("target=")
        else { return nil }
        func value(_ s: String, _ key: String) -> String? {
            let v = String(s.dropFirst(key.count))
            return v == "-" || v.isEmpty ? nil : v
        }
        return CommandLogEntry(id: id, at: at, ok: head[1] == "ok", verb: head[2],
                               caller: value(head[3], "caller="), target: value(head[4], "target="),
                               detail: head.dropFirst(5).joined(separator: " "), message: message)
    }

    /// Newest first, at most `limit`. Reads only the tail of a large log.
    package static func load(_ url: URL = defaultURL, limit: Int = 100) -> [CommandLogEntry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // partial first line
        var out: [CommandLogEntry] = []
        for (i, line) in lines.enumerated().reversed() where !line.isEmpty {
            if let e = parse(line, id: Int(start) + i) { out.append(e) }
            if out.count >= limit { break }
        }
        return out
    }
}

/// Compacts and clears that were scheduled but have not landed yet, for the
/// "queued" badge on a session row. self-console.sh types the command once the
/// session is idle, so a pending entry clears when its session is seen idle after
/// the typing delay, when the session ends, or after `timeout`.
package struct PendingCommands: Equatable {
    package struct Item: Equatable { package let verb: String; package let at: Date }
    package static let landDelay: TimeInterval = 10
    package static let timeout: TimeInterval = 15 * 60
    package private(set) var items: [String: Item] = [:]

    package init() {}

    package mutating func note(_ e: CommandLogEntry) {
        guard e.ok, e.verb == "compact" || e.verb == "clear", let t = e.target else { return }
        if let cur = items[t], cur.at >= e.at { return }
        items[t] = Item(verb: e.verb, at: e.at)
    }

    /// `sessions`: id -> is idle, for every live session.
    package mutating func observe(_ sessions: [String: Bool], now: Date = Date()) {
        items = items.filter { id, item in
            guard let idle = sessions[id] else { return false }
            if now.timeIntervalSince(item.at) > Self.timeout { return false }
            return !(idle && now.timeIntervalSince(item.at) >= Self.landDelay)
        }
    }

    package func verb(for session: String) -> String? { items[session]?.verb }
}
