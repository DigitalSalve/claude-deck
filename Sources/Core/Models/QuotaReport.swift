import Foundation

// MARK: - Per-Session Quota Analysis

package struct QuotaSessionReport: Identifiable {
    package let id: String          // sessionId (or agent-<id> for subagents)
    package let projectName: String
    package let model: String?
    package let turns: Int           // assistant message count
    package let baseInputPerTurn: Int   // first turn's input_tokens
    package let currentInputPerTurn: Int // last turn's input_tokens
    package let totalTokens: Int     // all token types summed
    package let totalOutputTokens: Int
    package let isActive: Bool
    package let lastActivity: Date
    package let entrypoint: String?
    /// Parent session's id if this row represents a subagent (sidechain) run.
    /// Nil for top-level sessions. Used to group subagents under their parent
    /// in the UI and to roll costs up accurately.
    package let parentSessionId: String?
    package let isSubagent: Bool

    package var wasteMultiplier: Double {
        guard baseInputPerTurn > 0 else { return 1.0 }
        return Double(currentInputPerTurn) / Double(baseInputPerTurn)
    }

    /// Tokens that could have been saved if context was kept near base level.
    /// Approximation: actual total input - (turns * base input per turn).
    package let totalInputTokens: Int
    /// Share of totalOutputTokens that was thinking (Claude 4.6+ reports it).
    package var thinkingTokens: Int = 0
    /// Server-side web tool calls made by the model.
    package var webSearchRequests: Int = 0
    package var webFetchRequests: Int = 0

    package var visibleOutputTokens: Int { max(0, totalOutputTokens - thinkingTokens) }
    package var thinkingShare: Double {
        guard totalOutputTokens > 0 else { return 0 }
        return Double(thinkingTokens) / Double(totalOutputTokens)
    }
    package var rotationSavingsTokens: Int {
        // Subagent runs are short and single-purpose; "rotation savings" is
        // a session-hygiene concept that doesn't apply to them.
        if isSubagent { return 0 }
        let ideal = turns * baseInputPerTurn + totalOutputTokens
        return max(0, totalTokens - ideal)
    }

    /// Resolved through the model catalog: family, display name, pricing.
    package var modelInfo: ModelInfo { ModelCatalog.shared.resolve(model) }

    /// Input here is the summed input+cache figure the analyzer produces, so
    /// it is billed at the plain input rate (an upper bound; cache reads are
    /// cheaper). Kept consistent with the pre-catalog behaviour.
    package var estimatedCost: Double {
        modelInfo.pricing.cost(input: totalInputTokens, output: totalOutputTokens)
    }

    package var rotationSavingsCost: Double {
        // Savings are entirely on the input side (context that wouldn't have grown)
        modelInfo.pricing.cost(input: rotationSavingsTokens, output: 0)
    }

    package var wasteColor: WasteLevel {
        if wasteMultiplier >= 5.0 { return .critical }
        if wasteMultiplier >= 3.0 { return .high }
        if wasteMultiplier >= 1.5 { return .moderate }
        return .efficient
    }

    package enum WasteLevel {
        case critical, high, moderate, efficient
    }
}

// MARK: - Aggregate Report

package struct QuotaReport {
    /// Flat list of every parsed session — top-level sessions AND subagent
    /// sidechains. Totals sum over all of them so quota math is accurate.
    package let sessions: [QuotaSessionReport]
    package let periodLabel: String

    /// Top-level sessions only (no subagents). Matches `sessions`' overall
    /// order (waste-first, worst at the top) — the UI iterates this for its
    /// primary table; subagents are nested underneath via `subagents(of:)`.
    package var rootSessions: [QuotaSessionReport] {
        sessions.filter { !$0.isSubagent }
    }

    /// Subagents (sidechains) whose parent is present in this report.
    /// Sorted oldest-first so nested rows read in spawn order.
    package func subagents(of parentId: String) -> [QuotaSessionReport] {
        sessions
            .filter { $0.isSubagent && $0.parentSessionId == parentId }
            .sorted { $0.lastActivity < $1.lastActivity }
    }

    /// Subagents whose parent isn't in the current report (parent outside
    /// the period cutoff, for example). Rendered at the end of the list so
    /// they don't disappear.
    package var orphanSubagents: [QuotaSessionReport] {
        let rootIds = Set(sessions.filter { !$0.isSubagent }.map { $0.id })
        return sessions.filter { s in
            s.isSubagent && !(s.parentSessionId.map { rootIds.contains($0) } ?? false)
        }
    }

    /// Combined tokens for a parent plus all of its subagents.
    package func rolledUpTokens(for parentId: String) -> Int {
        (sessions.first { $0.id == parentId }?.totalTokens ?? 0)
            + subagents(of: parentId).reduce(0) { $0 + $1.totalTokens }
    }

    package var totalSessions: Int { sessions.count }

    package var totalTokens: Int { sessions.reduce(0) { $0 + $1.totalTokens } }
    package var totalCost: Double { sessions.reduce(0) { $0 + $1.estimatedCost } }
    package var totalOutputTokens: Int { sessions.reduce(0) { $0 + $1.totalOutputTokens } }
    package var totalThinkingTokens: Int { sessions.reduce(0) { $0 + $1.thinkingTokens } }
    package var totalWebRequests: Int {
        sessions.reduce(0) { $0 + $1.webSearchRequests + $1.webFetchRequests }
    }

    package var sessionsOver5x: Int {
        // Waste multiplier is only meaningful for long-running top-level
        // sessions; subagents are short-lived and would inflate the count.
        sessions.filter { !$0.isSubagent && $0.wasteMultiplier >= 5.0 }.count
    }
    package var sessions3to5x: Int {
        sessions.filter {
            !$0.isSubagent && $0.wasteMultiplier >= 3.0 && $0.wasteMultiplier < 5.0
        }.count
    }

    package var worstSession: QuotaSessionReport? {
        sessions.filter { !$0.isSubagent }
            .max(by: { $0.wasteMultiplier < $1.wasteMultiplier })
    }

    package var potentialSavingsTokens: Int {
        sessions.reduce(0) { $0 + $1.rotationSavingsTokens }
    }
    package var potentialSavingsCost: Double {
        sessions.reduce(0) { $0 + $1.rotationSavingsCost }
    }
    package var withRotationTokens: Int { totalTokens - potentialSavingsTokens }

    package var savingsPercentage: Double {
        guard totalTokens > 0 else { return 0 }
        return Double(potentialSavingsTokens) / Double(totalTokens) * 100
    }

    package init(sessions: [QuotaSessionReport], periodLabel: String) {
        self.sessions = sessions.sorted { $0.wasteMultiplier > $1.wasteMultiplier }
        self.periodLabel = periodLabel
    }

    package static let empty = QuotaReport(sessions: [], periodLabel: "last 7 days")
}
