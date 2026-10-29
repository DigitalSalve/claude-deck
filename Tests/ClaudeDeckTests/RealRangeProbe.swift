import Foundation
import ClaudeDeckCore

func runRealRangeProbe() {
    guard ProcessInfo.processInfo.environment["CLAUDEDECK_PROBE"] == "1" else { return }
    suite("PROBE: custom range against the real ~/.claude") {
        let a = QuotaAnalyzer(claudeDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
        let cal = Calendar.current
        func day(_ s: String) -> Date { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)! }
        let r1 = DateInterval(start: cal.startOfDay(for: day("2026-10-01")), end: cal.startOfDay(for: day("2026-10-08")))
        let r2 = DateInterval(start: cal.startOfDay(for: day("2026-10-20")), end: Date())
        let last4h = a.analyze(period: .custom, customHours: 4)
        let oct1to7 = a.analyze(period: .custom, customHours: 4, customRange: r1)
        let oct20on = a.analyze(period: .custom, customHours: 4, customRange: r2)
        let sevenDays = a.analyze(period: .sevenDays)
        print("    last 4h: \(last4h.sessions.count) sessions, label '\(last4h.periodLabel)'")
        print("    Oct 1-7: \(oct1to7.sessions.count) sessions, label '\(oct1to7.periodLabel)'")
        print("    Oct 20-now: \(oct20on.sessions.count) sessions, label '\(oct20on.periodLabel)'")
        print("    7 days: \(sevenDays.sessions.count) sessions")
        expect(oct1to7.sessions.count != last4h.sessions.count, "a past range gives a different report than last 4h")
        expect(oct1to7.sessions.allSatisfy { $0.lastActivity >= r1.start }, "no session before the range start")
    }
}
