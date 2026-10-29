import Foundation

/// One parsed transcript's cumulative totals, as handed to the ledger.
package struct LedgerSample: Equatable {
    package let path: String
    package let sessionId: String
    package let model: String?
    package let isSubagent: Bool
    package let input: Int
    package let cacheRead: Int
    package let cacheWrite: Int
    package let output: Int
    package let thinking: Int
    package let turns: Int
    /// Timestamp of the last assistant message (file mtime when unknown).
    package let lastActivity: Date

    package init(path: String, sessionId: String, model: String?, isSubagent: Bool,
                 input: Int, cacheRead: Int, cacheWrite: Int, output: Int, thinking: Int,
                 turns: Int, lastActivity: Date) {
        self.path = path; self.sessionId = sessionId; self.model = model; self.isSubagent = isSubagent
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.output = output; self.thinking = thinking; self.turns = turns; self.lastActivity = lastActivity
    }
}

/// Per day, per model totals. `sessions` counts top-level sessions that were
/// active that day (subagents add tokens but not sessions).
package struct LedgerTotals: Codable, Equatable {
    package var input = 0
    package var cacheRead = 0
    package var cacheWrite = 0
    package var output = 0
    package var thinking = 0
    package var turns = 0
    package var sessions = 0
    package var cost: Double = 0

    package init() {}

    package var allTokens: Int { input + cacheRead + cacheWrite + output }

    package static func + (a: LedgerTotals, b: LedgerTotals) -> LedgerTotals {
        var r = a
        r.input += b.input; r.cacheRead += b.cacheRead; r.cacheWrite += b.cacheWrite
        r.output += b.output; r.thinking += b.thinking; r.turns += b.turns
        r.sessions += b.sessions; r.cost += b.cost
        return r
    }
}

/// A lightweight, durable account of token usage that outlives Claude Code's
/// transcript retention (`cleanupPeriodDays`, default 30) and the deck's own
/// caches. Stored at `~/.claude/claudedeck-ledger.json`:
///
/// - `days`: day (yyyy-MM-dd, local) -> model id -> totals. A few hundred
///   bytes per day. This is the history.
/// - `snapshots`: transcript path -> last totals the ledger has already
///   counted, so each refresh books only the delta. Pruned 60 days after a
///   transcript stops being seen.
///
/// Deltas are attributed to the day of the transcript's last activity, not
/// the wall clock, so a refresh after sleep still lands on the right day.
/// On the very first run (no ledger file) every existing transcript is
/// seeded onto its last-activity day, so history starts with what is still
/// on disk rather than a month of tokens on "today".
package final class UsageLedger: @unchecked Sendable {
    package static let shared = UsageLedger()

    package static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedeck-ledger.json")
    package static let defaultSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    package static let snapshotRetention: TimeInterval = 60 * 24 * 3600

    package struct Snapshot: Codable, Equatable {
        package var input = 0, cacheRead = 0, cacheWrite = 0, output = 0, thinking = 0, turns = 0
        package var day: String = ""
        package var lastSeen: Date = .distantPast
    }

    package struct Store: Codable, Equatable {
        package var version = 1
        package var days: [String: [String: LedgerTotals]] = [:]
        package var snapshots: [String: Snapshot] = [:]
        package var createdAt: Date? = nil
        package init() {}
    }

    private let url: URL?
    private let catalog: ModelCatalog
    private let lock = NSLock()
    private var store: Store
    private var loaded = false

    /// Writes are throttled: the file is rewritten at most once per
    /// `saveInterval`, with a deferred save for anything booked in between
    /// and `flush()` for app termination. Keeps a busy day from rewriting
    /// a few hundred KB every second.
    package var saveInterval: TimeInterval = 30
    private var lastSave: Date = .distantPast
    private var dirty = false
    private var pendingSave: DispatchWorkItem?
    package private(set) var saveCount = 0

    package init(url: URL? = UsageLedger.defaultURL, catalog: ModelCatalog = .shared) {
        self.url = url
        self.catalog = catalog
        if let url, let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(Store.self, from: data) {
            store = s; loaded = true
        } else {
            store = Store()
        }
    }

    /// True until the first `record` has run on a machine with no ledger.
    package var isFirstRun: Bool { lock.lock(); defer { lock.unlock() }; return !loaded && store.createdAt == nil }

    package static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Book the deltas for a set of parsed transcripts. Returns true when
    /// anything changed (and was saved).
    @discardableResult
    package func record(_ samples: [LedgerSample], now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        if store.createdAt == nil { store.createdAt = now; changed = true }

        for s in samples where s.turns > 0 {
            let day = Self.dayKey(s.lastActivity)
            let modelKey = s.model ?? "unknown"
            var snap = store.snapshots[s.path] ?? Snapshot()
            let isNew = store.snapshots[s.path] == nil

            var d = LedgerTotals()
            d.input = s.input - snap.input
            d.cacheRead = s.cacheRead - snap.cacheRead
            d.cacheWrite = s.cacheWrite - snap.cacheWrite
            d.output = s.output - snap.output
            d.thinking = s.thinking - snap.thinking
            d.turns = s.turns - snap.turns

            // A transcript that shrank was rewritten; restart from its current
            // totals without booking a negative or a double count.
            let shrank = d.input < 0 || d.cacheRead < 0 || d.cacheWrite < 0 || d.output < 0 || d.turns < 0
            if shrank { d = LedgerTotals() }

            let hasDelta = d.input > 0 || d.cacheRead > 0 || d.cacheWrite > 0 || d.output > 0
            if hasDelta {
                if !s.isSubagent && (isNew || snap.day != day) { d.sessions = 1 }
                d.cost = catalog.resolve(s.model).pricing.cost(
                    input: d.input, output: d.output, cacheRead: d.cacheRead, cacheWrite: d.cacheWrite)
                var byModel = store.days[day] ?? [:]
                byModel[modelKey] = (byModel[modelKey] ?? LedgerTotals()) + d
                store.days[day] = byModel
                changed = true
            }

            let newSnap = Snapshot(input: s.input, cacheRead: s.cacheRead, cacheWrite: s.cacheWrite,
                                   output: s.output, thinking: s.thinking, turns: s.turns,
                                   day: hasDelta ? day : snap.day, lastSeen: now)
            if newSnap != snap || isNew { store.snapshots[s.path] = newSnap; changed = true }
            _ = snap; snap = newSnap
        }

        // Forget snapshots of transcripts that have not been seen for a while
        // (deleted by Claude Code's retention sweep). Their days stay booked.
        let cutoff = now.addingTimeInterval(-Self.snapshotRetention)
        let stale = store.snapshots.filter { $0.value.lastSeen < cutoff }.map(\.key)
        if !stale.isEmpty { for k in stale { store.snapshots.removeValue(forKey: k) }; changed = true }

        DebugLog.write("[ledger] record: \(samples.count) samples changed=\(changed) dirty=\(dirty) sinceSave=\(Int(min(1e6, now.timeIntervalSince(lastSave))))s")
        if changed { dirty = true; saveIfDue(now: now) }
        return changed
    }

    /// Lock must be held. Saves now when the interval has passed, otherwise
    /// schedules one deferred save at the end of the interval.
    private func saveIfDue(now: Date) {
        guard dirty else { return }
        let elapsed = now.timeIntervalSince(lastSave)
        if elapsed >= saveInterval {
            saveLocked(now: now)
        } else if pendingSave == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.pendingSave = nil
                if self.dirty { self.saveLocked(now: Date()) }
            }
            pendingSave = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (saveInterval - elapsed), execute: work)
        }
    }

    /// Write immediately (app going to background / quitting).
    package func flush(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        pendingSave?.cancel(); pendingSave = nil
        if dirty { saveLocked(now: now) }
    }

    private func saveLocked(now: Date) {
        DebugLog.write("[ledger] save #\(saveCount + 1)")
        dirty = false
        lastSave = now
        saveCount += 1
        loaded = true
        guard let url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Reads

    package func allDays() -> [String: [String: LedgerTotals]] {
        lock.lock(); defer { lock.unlock() }; return store.days
    }

    package var firstDay: String? { allDays().keys.min() }
    package var lastDay: String? { allDays().keys.max() }
    package var dayCount: Int { allDays().count }

    /// Per-model totals for days >= `fromDay` (inclusive, yyyy-MM-dd) and
    /// <= `toDay` when given.
    package func totals(fromDay: String? = nil, toDay: String? = nil) -> [String: LedgerTotals] {
        var out: [String: LedgerTotals] = [:]
        for (day, byModel) in allDays() {
            if let f = fromDay, day < f { continue }
            if let t = toDay, day > t { continue }
            for (model, t) in byModel { out[model] = (out[model] ?? LedgerTotals()) + t }
        }
        return out
    }

    /// Totals for the last `days` days ending today.
    package func totals(lastDays days: Int, now: Date = Date()) -> [String: LedgerTotals] {
        let from = Self.dayKey(now.addingTimeInterval(-Double(max(0, days - 1)) * 86400))
        return totals(fromDay: from)
    }

    /// Month (yyyy-MM) -> model -> totals, newest month first.
    package func monthly() -> [(month: String, byModel: [String: LedgerTotals])] {
        var months: [String: [String: LedgerTotals]] = [:]
        for (day, byModel) in allDays() {
            let m = String(day.prefix(7))
            var acc = months[m] ?? [:]
            for (model, t) in byModel { acc[model] = (acc[model] ?? LedgerTotals()) + t }
            months[m] = acc
        }
        return months.keys.sorted(by: >).map { ($0, months[$0]!) }
    }

    package func grand(_ byModel: [String: LedgerTotals]) -> LedgerTotals {
        byModel.values.reduce(LedgerTotals(), +)
    }

    // MARK: - Retention

    /// Claude Code's transcript retention in days (`cleanupPeriodDays` in
    /// settings.json; the product default is 30 when unset).
    package static func cleanupPeriodDays(settingsURL: URL = defaultSettingsURL) -> Int {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 30 }
        if let n = json["cleanupPeriodDays"] as? Int { return n }
        if let d = json["cleanupPeriodDays"] as? Double { return Int(d) }
        return 30
    }
}
