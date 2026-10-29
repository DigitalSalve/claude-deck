import Foundation
import SwiftUI

// MARK: - Plan

package enum ClaudePlan: String, CaseIterable, Identifiable {
    case free   = "Free"
    case pro    = "Pro"
    case max5x  = "Max 5x"
    case max20x = "Max 20x"

    package var id: String { rawValue }

    /// Plan units per 5-hour rolling window (community-estimated table values)
    package var sessionPlanUnits: Int {
        switch self {
        case .free:   return 4_400
        case .pro:    return 44_000
        case .max5x:  return 88_000
        case .max20x: return 220_000
        }
    }

    /// Effective output token ceiling for the 5h window.
    /// Calibrated from observed data: 30K output tokens → 1% in our count vs 2% on claude.ai,
    /// implying ~7 output tokens per plan unit (not 10 as previously estimated).
    package var sessionOutputTokenLimit: Int { sessionPlanUnits * 7 }

    /// Weekly all-models output token limit, calibrated from claude.ai for
    /// Max 20x (2.8M / 42% = 6.67M). Other plans scaled by sessionPlanUnits.
    /// Only used as a FALLBACK when Claude Code's own rate_limits are not
    /// available (see UsageWindows).
    package var weeklyAllOutputTokenLimit: Int {
        Int(6_700_000.0 * Double(sessionPlanUnits) / 220_000.0)
    }
}

package struct ClaudeSession: Identifiable, Codable {
    package let id: String // sessionId UUID
    package let pid: Int?
    package let cwd: String
    package let startedAt: Double? // epoch ms
    package let kind: String?
    package let entrypoint: String?
    /// Claude Code's own session name (`name` in the registry, derived or
    /// user-set via /rename). Preferred over the cwd folder for display.
    package let name: String?
    package let nameSource: String?
    /// `busy` (model running), `idle` (waiting for input), `shell` (a
    /// foreground shell command). Nil on older Claude Code versions.
    package let status: String?
    package let claudeVersion: String?

    package init(id: String, pid: Int?, cwd: String, startedAt: Double?, kind: String?,
                 entrypoint: String?, name: String? = nil, nameSource: String? = nil,
                 status: String? = nil, claudeVersion: String? = nil) {
        self.id = id; self.pid = pid; self.cwd = cwd; self.startedAt = startedAt
        self.kind = kind; self.entrypoint = entrypoint; self.name = name
        self.nameSource = nameSource; self.status = status; self.claudeVersion = claudeVersion
    }

    package var isActive: Bool { pid != nil && processIsRunning(pid!) }
    package var folderName: String { URL(fileURLWithPath: cwd).lastPathComponent }
    package var displayName: String {
        if let name = resolvedName { return name }
        if let name, !name.isEmpty { return name }
        return folderName
    }

    package enum Status: String { case busy, idle, shell, unknown }
    package var sessionStatus: Status { status.flatMap(Status.init) ?? .unknown }
    package var startDate: Date? {
        guard let ts = startedAt else { return nil }
        return Date(timeIntervalSince1970: ts / 1000)
    }
    /// Cached once at scan time. SwiftUI renders this getter many times per
    /// row per refresh — we must NEVER spawn /bin/ps on the main thread here.
    /// Populated in SessionManager.scanActiveSessions via computeIsDesktop().
    package var cachedIsDesktop: Bool?

    package var isDesktop: Bool {
        if let cached = cachedIsDesktop { return cached }
        // Fallback: no pid (e.g. historical record) → use entrypoint hint.
        // We deliberately avoid subprocess calls in this getter to keep the
        // render path allocation-free and main-thread-safe.
        return entrypoint == "claude-desktop"
    }
    package var isWeb: Bool { entrypoint == "web" || entrypoint == "claude-web" }
    /// Headless Agent SDK sessions (`sdk-cli`): no terminal to resume into.
    package var isSDK: Bool { entrypoint == "sdk-cli" }
    package var isCLI: Bool { !isDesktop && !isWeb && !isSDK }
    package var sourceLabel: String { isWeb ? "Web" : isSDK ? "SDK" : isDesktop ? "Desktop" : "Terminal" }
    package var sourceColor: Color { isWeb ? .orange : isSDK ? .teal : isDesktop ? .purple : .blue }
    package var resolvedName: String?
    package var firstPrompt: String?
    /// Claude Code's generated title for the conversation (`ai-title` record).
    package var title: String?
    /// The most recent user prompt (`last-prompt` record).
    package var lastPrompt: String?
    /// Row preview: the generated title when Claude Code has one, else the opening prompt.
    package var preview: String? { title ?? firstPrompt }

    /// Resolve `cachedIsDesktop` by running /bin/ps once per session. Call this
    /// OFF the main thread (e.g. in scanActiveSessions on a utility queue).
    package mutating func resolveIsDesktop() {
        guard let pid else {
            cachedIsDesktop = entrypoint == "claude-desktop"
            return
        }
        cachedIsDesktop = !pidHasControllingTerminal(pid)
    }

    package enum CodingKeys: String, CodingKey {
        case pid, cwd, startedAt, kind, entrypoint, name, nameSource, status
        case id = "sessionId"
        case claudeVersion = "version"
    }
}

package struct SessionHistory: Identifiable {
    package let id: String
    package let projectPath: String
    package let lastActivity: Date
    package let messageCount: Int
    package let totalInputTokens: Int
    package let totalCacheReadTokens: Int
    package let totalCacheWriteTokens: Int
    package let totalOutputTokens: Int
    package let model: String?
    package let name: String?
    package let entrypoint: String?
    package var firstPrompt: String?
    package let firstActivity: Date?
    package var title: String?
    package var lastPrompt: String?
    package var preview: String? { title ?? firstPrompt }

    package init(id: String, projectPath: String, lastActivity: Date, messageCount: Int,
                 totalInputTokens: Int, totalCacheReadTokens: Int, totalCacheWriteTokens: Int,
                 totalOutputTokens: Int, model: String?, name: String?, entrypoint: String?,
                 firstPrompt: String? = nil, firstActivity: Date? = nil) {
        self.id = id; self.projectPath = projectPath; self.lastActivity = lastActivity
        self.messageCount = messageCount; self.totalInputTokens = totalInputTokens
        self.totalCacheReadTokens = totalCacheReadTokens; self.totalCacheWriteTokens = totalCacheWriteTokens
        self.totalOutputTokens = totalOutputTokens; self.model = model; self.name = name
        self.entrypoint = entrypoint; self.firstPrompt = firstPrompt; self.firstActivity = firstActivity
    }

    package var projectName: String {
        let decoded = projectPath
            .replacingOccurrences(of: "-Users-", with: "/Users/")
            .replacingOccurrences(of: "-", with: "/")
        return URL(fileURLWithPath: decoded).lastPathComponent
    }

    package var isDesktop: Bool { entrypoint == "claude-desktop" }
    package var isWeb: Bool { entrypoint == "web" || entrypoint == "claude-web" }
    package var isSDK: Bool { entrypoint == "sdk-cli" }
    package var isCLI: Bool { !isDesktop && !isWeb && !isSDK }
    package var sourceLabel: String { isWeb ? "Web" : isSDK ? "SDK" : isDesktop ? "Desktop" : "Terminal" }
    package var sourceColor: Color { isWeb ? .orange : isSDK ? .teal : isDesktop ? .purple : .blue }

    /// Resolved through the model catalog: family, display name, pricing.
    package var modelInfo: ModelInfo { ModelCatalog.shared.resolve(model) }
    package var modelFamily: ModelFamily { modelInfo.family }

    package var isSonnet: Bool { modelFamily == .sonnet }
    package var isOpus:   Bool { modelFamily == .opus }
    package var isHaiku:  Bool { modelFamily == .haiku }
    package var isFable:  Bool { modelFamily == .fable || modelFamily == .mythos }

    package var estimatedCost: Double {
        modelInfo.pricing.cost(input: totalInputTokens, output: totalOutputTokens,
                               cacheRead: totalCacheReadTokens, cacheWrite: totalCacheWriteTokens)
    }
}

package struct UsageStats {
    package var activeSessions: Int = 0
    package var totalSessions: Int = 0
    package var sessionsByModel: [String: Int] = [:]
    package var fiveHourTokens: Int = 0
    package var windowStart: Date? = nil
    package var windowIsActive: Bool = false

    package var windowEnd: Date? { windowStart.map { $0.addingTimeInterval(5 * 3600) } }
    package var windowSecondsRemaining: TimeInterval? {
        guard let end = windowEnd else { return nil }
        return max(0, end.timeIntervalSinceNow)
    }

    package var sevenDayAllTokens: Int = 0
    package var weeklyAllResetDate: Date? = nil
    package var isPeakHours: Bool = false
    /// Claude Code's own rate-limit windows, when the status line hook has
    /// written them. Nil = fall back to the token estimate.
    package var usageWindows: UsageWindows? = nil
    package var allTimeTokens: Int = 0
    package var allTimeCost: Double = 0

    /// The date the all-models weekly window resets (oldest session in window + 7 days)
    package var weeklyAllResetsIn: String? { resetLabel(for: weeklyAllResetDate) }

    private func resetLabel(for date: Date?) -> String? {
        guard let date else { return nil }
        guard date.timeIntervalSinceNow > 0 else { return nil }
        let df = DateFormatter()
        df.dateFormat = "EEE h:mm a"
        return "Resets \(df.string(from: date))"
    }

    package init() {}
}

private func processIsRunning(_ pid: Int) -> Bool {
    kill(pid_t(pid), 0) == 0
}

/// Returns true if the process has a controlling terminal (i.e. it's running in a terminal emulator).
/// Processes launched by the Desktop app have TTY "??" (no controlling terminal).
private func pidHasControllingTerminal(_ pid: Int) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-p", "\(pid)", "-o", "tty="]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    try? proc.run()
    proc.waitUntilExit()
    let tty = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !tty.isEmpty && tty != "??"
}
