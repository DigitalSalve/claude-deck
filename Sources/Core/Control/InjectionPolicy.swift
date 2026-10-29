import Foundation

/// Who may type into which terminal:
///
/// - A session acting on ITSELF is always allowed.
/// - A human at a plain shell (no Claude session in the connecting process's
///   ancestry) is the owner at the keyboard and is allowed.
/// - A session acting on a PEER needs both: the owner-designated orchestrator
///   role (`~/.claude/claudedeck/orchestrator-roles.json`) AND a live owner-word
///   grant (`~/.claude/claudedeck/injection-grant.json`, 600 s TTL, consumed on use,
///   tty must match the target when both are present). Every allowed peer
///   injection is appended to `injection-log.jsonl`.
package struct InjectionPolicy {
    package enum Decision: Equatable {
        case allowSelf
        case allowHuman
        case allowPeer(grantTTY: String)
        case deny(String)

        package var isAllowed: Bool {
            if case .deny = self { return false }
            return true
        }
    }

    package static let grantTTL: TimeInterval = 600

    package let rolesURL: URL
    package let grantURL: URL
    package let logURL: URL

    package static let defaultDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedeck")

    package init(directory: URL = InjectionPolicy.defaultDir) {
        rolesURL = directory.appendingPathComponent("orchestrator-roles.json")
        grantURL = directory.appendingPathComponent("injection-grant.json")
        logURL   = directory.appendingPathComponent("injection-log.jsonl")
    }

    /// `callerSession` nil means no Claude session was found in the caller's
    /// process ancestry (a human shell). `targetTTY` nil means the target's tty
    /// could not be read; a grant that names a tty then still applies.
    package func evaluate(callerSession: String?, targetSession: String,
                          targetTTY: String?, now: Date = Date()) -> Decision {
        guard let caller = callerSession, !caller.isEmpty else { return .allowHuman }
        if caller == targetSession { return .allowSelf }

        guard hasOrchestratorRole(sessionId: caller) else {
            return .deny("this session does not hold the orchestrator role. Only a session the owner has designated, with the owner's own words, in \(rolesURL.path) may act on another session. Do not add yourself; ask the owner.")
        }

        guard let data = try? Data(contentsOf: grantURL) else {
            return .deny("acting on another session requires a one-shot grant written by the owner at \(grantURL.path), and none exists. Do not write one yourself or try another route; ask the owner.")
        }
        guard let g = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .deny("the grant file \(grantURL.path) is unreadable or invalid. The owner must write a fresh one with their own words.")
        }
        let word = (g["owner_word"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else {
            return .deny("grant file has no owner_word. A grant without the owner's verbatim authorizing words is invalid.")
        }
        let granted: Double = (g["granted_at"] as? Double) ?? Double(g["granted_at"] as? Int ?? 0)
        let age = now.timeIntervalSince1970 - granted
        guard age >= 0, age <= Self.grantTTL else {
            try? FileManager.default.removeItem(at: grantURL)
            return .deny("injection grant expired (600s TTL). A fresh owner word and a fresh grant are required.")
        }
        let grantTTY = (g["tty"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if let t = targetTTY, !t.isEmpty, !grantTTY.isEmpty, t != grantTTY {
            return .deny("grant is for \(grantTTY) but the command targets \(t). One grant, one target.")
        }
        return .allowPeer(grantTTY: grantTTY)
    }

    /// Call after a peer injection has been dispatched: deletes the grant
    /// (one grant, one injection) and appends an audit line.
    package func consumePeerGrant(targetTTY: String?, commandHead: String, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry: [String: Any] = [
            "ts": Int(now.timeIntervalSince1970),
            "tty": targetTTY ?? "",
            "cmd_head": String(commandHead.prefix(200)),
            "via": "claudedeck",
        ]
        if let line = try? JSONSerialization.data(withJSONObject: entry),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line); handle.write(Data("\n".utf8))
            try? handle.close()
        } else if let line = try? JSONSerialization.data(withJSONObject: entry) {
            try? (line + Data("\n".utf8)).write(to: logURL)
        }
        try? FileManager.default.removeItem(at: grantURL)
    }

    package func hasOrchestratorRole(sessionId: String) -> Bool {
        guard let data = try? Data(contentsOf: rolesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [[String: Any]]
        else { return false }
        return sessions.contains { s in
            (s["session_id"] as? String) == sessionId
                && !((s["owner_word"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
