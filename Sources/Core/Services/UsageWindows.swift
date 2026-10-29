import Foundation

/// One rate-limit window as Claude Code reports it to status line scripts:
/// `{"used_percentage": 60, "resets_at": 1793044800}`.
package struct UsageWindow: Codable, Equatable {
    package let usedPercentage: Int
    package let resetsAt: Date

    package init(usedPercentage: Int, resetsAt: Date) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    /// Claude Code only writes while a session is running. If the window
    /// has already reset since the last write, real usage is back to zero.
    package func current(now: Date = Date()) -> UsageWindow {
        resetsAt <= now ? UsageWindow(usedPercentage: 0, resetsAt: resetsAt) : self
    }

    package func secondsUntilReset(now: Date = Date()) -> TimeInterval {
        max(0, resetsAt.timeIntervalSince(now))
    }
}

/// The live rate-limit picture Claude Code hands to the status line
/// (`rate_limits.five_hour`, `rate_limits.seven_day`, plus any extra
/// per-model windows a plan exposes). The status line hook
/// (`claudedeck statusline`, see StatusLine.swift) writes the whole status
/// line input to `~/.claude/claudedeck-usage.json`; this type reads it.
///
/// These are Anthropic's own numbers for the signed-in account, so they
/// replace the plan-unit estimate whenever the file exists.
package struct UsageWindows: Equatable {
    package var windows: [String: UsageWindow]
    /// When the file was written (its mtime). Shown as "as of …" when old.
    package var updatedAt: Date
    package var sessionId: String?
    package var model: String?
    package var claudeVersion: String?

    package static let fiveHourKey = "five_hour"
    package static let sevenDayKey = "seven_day"

    package var fiveHour: UsageWindow? { windows[Self.fiveHourKey] }
    package var sevenDay: UsageWindow? { windows[Self.sevenDayKey] }

    /// Any additional windows (e.g. a per-model weekly cap), keyed by the
    /// raw rate_limits key, in a stable order for display.
    package var extraWindows: [(key: String, window: UsageWindow)] {
        windows.keys
            .filter { $0 != Self.fiveHourKey && $0 != Self.sevenDayKey }
            .sorted()
            .map { ($0, windows[$0]!) }
    }

    package var isEmpty: Bool { windows.isEmpty }

    package func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(updatedAt) }

    package static let defaultURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedeck-usage.json")

    package init(windows: [String: UsageWindow], updatedAt: Date,
                 sessionId: String? = nil, model: String? = nil, claudeVersion: String? = nil) {
        self.windows = windows; self.updatedAt = updatedAt
        self.sessionId = sessionId; self.model = model; self.claudeVersion = claudeVersion
    }

    /// Reads the hook's file. Nil when the file is absent or carries no
    /// `rate_limits` (API-key sessions and some gateways omit it).
    package static func load(from url: URL = defaultURL, now: Date = Date()) -> UsageWindows? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? now
        return parse(data, updatedAt: mtime)
    }

    /// Parses a status line input document. Exposed for tests.
    package static func parse(_ data: Data, updatedAt: Date) -> UsageWindows? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any]
        else { return nil }

        var windows: [String: UsageWindow] = [:]
        for (key, value) in limits {
            guard let dict = value as? [String: Any],
                  let pct = dict["used_percentage"] as? Int ?? (dict["used_percentage"] as? Double).map(Int.init),
                  let resets = dict["resets_at"] as? Double ?? (dict["resets_at"] as? Int).map(Double.init)
            else { continue }
            windows[key] = UsageWindow(usedPercentage: max(0, pct),
                                       resetsAt: Date(timeIntervalSince1970: resets))
        }
        guard !windows.isEmpty else { return nil }

        let model = (json["model"] as? [String: Any])?["id"] as? String
        return UsageWindows(windows: windows, updatedAt: updatedAt,
                            sessionId: json["session_id"] as? String,
                            model: model,
                            claudeVersion: json["version"] as? String)
    }
}
