import Foundation
import ClaudeDeckCore

func runUsageLedgerTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-ledger-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("ledger.json")
    let catalog = ModelCatalog(overridesURL: nil, learnedURL: nil)
    let day1 = Date(timeIntervalSince1970: 1_790_000_000)          // some day
    let day2 = day1.addingTimeInterval(2 * 86400)
    let d1 = UsageLedger.dayKey(day1), d2 = UsageLedger.dayKey(day2)
    func sample(_ path: String, model: String = "claude-sonnet-5-5", sub: Bool = false,
                input: Int, cr: Int = 0, cw: Int = 0, out: Int, think: Int = 0, turns: Int, at: Date) -> LedgerSample {
        LedgerSample(path: path, sessionId: path, model: model, isSubagent: sub, input: input, cacheRead: cr,
                     cacheWrite: cw, output: out, thinking: think, turns: turns, lastActivity: at)
    }

    suite("UsageLedger — first run seeds history onto last-activity days") {
        let l = UsageLedger(url: url, catalog: catalog); l.saveInterval = 0
        expect(l.isFirstRun, "fresh ledger is first run")
        let changed = l.record([
            sample("a", input: 1_000, out: 100, turns: 3, at: day1),
            sample("b", model: "claude-opus-5-5", input: 2_000, out: 200, turns: 5, at: day2),
        ], now: day2)
        expect(changed, "first record changes the store")
        let days = l.allDays()
        expectEqual(days[d1]?["claude-sonnet-5-5"]?.input, 1_000, "sonnet booked on its own day")
        expectEqual(days[d2]?["claude-opus-5-5"]?.output, 200, "opus booked on its own day")
        expectEqual(days[d1]?["claude-sonnet-5-5"]?.sessions, 1, "session counted once")
        let cost = days[d2]?["claude-opus-5-5"]?.cost ?? 0
        expect(abs(cost - (2_000.0 / 1e6 * 4 + 200.0 / 1e6 * 20)) < 1e-9, "cost at catalog rates (opus 5.5 $4/$20)")
        expect(FileManager.default.fileExists(atPath: url.path), "ledger persisted")
    }

    suite("UsageLedger — deltas only, no double counting") {
        let l = UsageLedger(url: url, catalog: catalog); l.saveInterval = 0
        expect(!l.isFirstRun, "reloaded ledger is not first run")
        let unchanged = l.record([sample("a", input: 1_000, out: 100, turns: 3, at: day1)], now: day2)
        let before = l.allDays()[d1]?["claude-sonnet-5-5"]
        expectEqual(before?.input, 1_000, "same totals book nothing")
        _ = unchanged
        l.record([sample("a", input: 1_500, out: 160, turns: 4, at: day2)], now: day2)
        let d1t = l.allDays()[d1]?["claude-sonnet-5-5"]
        let d2t = l.allDays()[d2]?["claude-sonnet-5-5"]
        expectEqual(d1t?.input, 1_000, "earlier day untouched")
        expectEqual(d2t?.input, 500, "only the delta lands on the new day")
        expectEqual(d2t?.output, 60, "output delta")
        expectEqual(d2t?.turns, 1, "turn delta")
        expectEqual(d2t?.sessions, 1, "session counted again on a new day")
        l.record([sample("a", input: 1_700, out: 170, turns: 5, at: day2)], now: day2)
        expectEqual(l.allDays()[d2]?["claude-sonnet-5-5"]?.sessions, 1, "same day, session not recounted")
        expectEqual(l.allDays()[d2]?["claude-sonnet-5-5"]?.input, 700, "second delta accumulates")
    }

    suite("UsageLedger — subagents add tokens, not sessions; shrink resets") {
        let l = UsageLedger(url: url, catalog: catalog); l.saveInterval = 0
        l.record([sample("a/sub1", sub: true, input: 300, out: 30, turns: 2, at: day2)], now: day2)
        let t = l.allDays()[d2]?["claude-sonnet-5-5"]
        expectEqual(t?.input, 1_000, "subagent tokens added")
        expectEqual(t?.sessions, 1, "subagent does not count as a session")
        // transcript rewritten smaller: nothing negative, nothing double booked
        let beforeInput = t?.input
        l.record([sample("a", input: 100, out: 10, turns: 1, at: day2)], now: day2)
        expectEqual(l.allDays()[d2]?["claude-sonnet-5-5"]?.input, beforeInput, "shrunken transcript books nothing")
        l.record([sample("a", input: 150, out: 15, turns: 2, at: day2)], now: day2)
        expectEqual(l.allDays()[d2]?["claude-sonnet-5-5"]?.input, (beforeInput ?? 0) + 50, "growth after a shrink books the new delta only")
    }

    suite("UsageLedger — reads and retention") {
        let l = UsageLedger(url: url, catalog: catalog); l.saveInterval = 0
        expectEqual(l.firstDay, d1, "first day")
        expectEqual(l.dayCount, 2, "two days booked")
        let all = l.totals()
        expectEqual(all["claude-opus-5-5"]?.input, 2_000, "totals across days by model")
        let win = l.totals(lastDays: 1, now: day2)
        expectEqual(win["claude-opus-5-5"]?.input, 2_000, "opus (booked on day2) is inside the last-1-day window")
        expectEqual(win["claude-sonnet-5-5"]?.input, 1_050, "last-1-day window = day2 only")
        let months = l.monthly()
        expect(!months.isEmpty && months.first!.month.count == 7, "monthly keys are yyyy-MM")
        expectEqual(l.grand(all).input, 4_050, "grand total input (1000+500+200 a, 300 sub, 2000 b, 50 after shrink)")

        // snapshots of unseen transcripts are pruned after 60 days; days remain
        l.record([], now: day2.addingTimeInterval(61 * 86400))
        let l2 = UsageLedger(url: url, catalog: catalog); l2.saveInterval = 0
        expectEqual(l2.dayCount, 2, "booked days survive snapshot pruning")
        l2.record([sample("a", input: 150, out: 15, turns: 2, at: day2)], now: day2.addingTimeInterval(62 * 86400))
        expectEqual(l2.allDays()[d2]?["claude-sonnet-5-5"]?.input, 1_050 + 150, "a pruned transcript seen again seeds its current totals once")

        let settings = dir.appendingPathComponent("settings.json")
        try? Data(#"{"cleanupPeriodDays": 90}"#.utf8).write(to: settings)
        expectEqual(UsageLedger.cleanupPeriodDays(settingsURL: settings), 90, "reads cleanupPeriodDays")
        expectEqual(UsageLedger.cleanupPeriodDays(settingsURL: dir.appendingPathComponent("nope.json")), 30, "default 30 when unset")

        expectEqual(UsageLedger.dayKey(day1).count, 10, "day key yyyy-MM-dd")
        let bogus = Date(timeIntervalSince1970: 1_577_750_400) // 2019-12-31
        let mt = Date(timeIntervalSince1970: 1_790_000_000)
        expectEqual(QuotaAnalyzer.saneActivityDate(bogus, fallback: mt), mt, "pre-2024 timestamp falls back to mtime")
        expectEqual(QuotaAnalyzer.saneActivityDate(nil, fallback: mt), mt, "nil timestamp falls back to mtime")
        expectEqual(QuotaAnalyzer.saneActivityDate(day1, fallback: mt), day1, "plausible timestamp kept")
        let mem = UsageLedger(url: nil, catalog: catalog)
        mem.record([sample("x", input: 1, out: 1, turns: 1, at: day1)])
        expectEqual(mem.dayCount, 1, "in-memory ledger works without a file")
    }
}

func runLedgerThrottleTests() {
    suite("UsageLedger — save throttling") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-ledger-t-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.json")
        let l = UsageLedger(url: url, catalog: ModelCatalog(overridesURL: nil, learnedURL: nil))
        l.saveInterval = 3600
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func s(_ n: Int) -> LedgerSample {
            LedgerSample(path: "p", sessionId: "p", model: "claude-sonnet-5-5", isSubagent: false,
                         input: n, cacheRead: 0, cacheWrite: 0, output: 1, thinking: 0, turns: 1, lastActivity: t0)
        }
        l.record([s(100)], now: t0)
        expectEqual(l.saveCount, 1, "first booking saves immediately")
        l.record([s(200)], now: t0.addingTimeInterval(1))
        l.record([s(300)], now: t0.addingTimeInterval(2))
        expectEqual(l.saveCount, 1, "bookings inside the interval do not rewrite the file")
        l.flush(now: t0.addingTimeInterval(2))
        expectEqual(l.saveCount, 2, "flush writes the pending changes")
        l.flush(now: t0.addingTimeInterval(2))
        expectEqual(l.saveCount, 2, "flush with nothing dirty is a no-op")
        l.record([s(400)], now: t0.addingTimeInterval(4000))
        expectEqual(l.saveCount, 3, "a booking after the interval saves immediately")
        let reloaded = UsageLedger(url: url, catalog: ModelCatalog(overridesURL: nil, learnedURL: nil))
        expectEqual(reloaded.totals()["claude-sonnet-5-5"]?.input, 400, "everything booked reached disk")
    }

    suite("QuotaLiveStore — background debounce") {
        let store = QuotaLiveStore()
        store.backgroundDebounce = 60
        expectEqual(store.effectiveDelay(for: 0.5), 60, "off-screen events coalesce to the background interval")
        expectEqual(store.effectiveDelay(for: 0), 0, "explicit refresh is never slowed")
        store.isVisible = true
        expectEqual(store.effectiveDelay(for: 0.5), 0.5, "on-screen keeps the fast debounce")
        store.isVisible = false
        expectEqual(store.effectiveDelay(for: 120), 120, "a longer requested delay is kept")
        expectEqual(store.tickInterval, 300, "off-screen tick every 5 minutes")
        store.isVisible = true
        expectEqual(store.tickInterval, 20, "on-screen tick every 20 seconds")
    }
}
