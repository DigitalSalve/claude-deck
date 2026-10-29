import Foundation
import ClaudeDeckCore

func runUsageWindowsTests() {
    // Shape captured from a live Claude Code 2.1.310 status line input.
    let sample = #"{"session_id":"abc","version":"2.1.310","model":{"id":"claude-fable-5-1","display_name":"Fable 5.1"},"rate_limits":{"five_hour":{"used_percentage":60,"resets_at":1793044800},"seven_day":{"used_percentage":51,"resets_at":1793534400}},"cwd":"/tmp"}"#
    let written = Date(timeIntervalSince1970: 1793040000)

    suite("UsageWindows — Parse status line input") {
        let w = UsageWindows.parse(Data(sample.utf8), updatedAt: written)
        expect(w != nil, "parses rate_limits")
        expectEqual(w?.fiveHour?.usedPercentage, 60, "five_hour percentage")
        expectEqual(w?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1793044800), "five_hour resets_at")
        expectEqual(w?.sevenDay?.usedPercentage, 51, "seven_day percentage")
        expectEqual(w?.sessionId, "abc", "session id carried")
        expectEqual(w?.model, "claude-fable-5-1", "model id carried")
        expectEqual(w?.claudeVersion, "2.1.310", "version carried")
        expectEqual(w?.updatedAt, written, "updatedAt from caller (file mtime)")
        expect(w?.extraWindows.isEmpty == true, "no extra windows in sample")
    }

    suite("UsageWindows — Extra per-model windows and odd numerics") {
        let extra = #"{"rate_limits":{"five_hour":{"used_percentage":12.0,"resets_at":1793044800.0},"seven_day":{"used_percentage":3,"resets_at":1793534400},"seven_day_opus":{"used_percentage":40,"resets_at":1793534400}}}"#
        let w = UsageWindows.parse(Data(extra.utf8), updatedAt: written)
        expectEqual(w?.fiveHour?.usedPercentage, 12, "double percentage accepted")
        expectEqual(w?.extraWindows.count, 1, "one extra window")
        expectEqual(w?.extraWindows.first?.key, "seven_day_opus", "extra window key")
        expectEqual(w?.extraWindows.first?.window.usedPercentage, 40, "extra window pct")
    }

    suite("UsageWindows — Absent or empty rate_limits") {
        expectNil(UsageWindows.parse(Data(#"{"session_id":"x"}"#.utf8), updatedAt: written), "no rate_limits = nil")
        expectNil(UsageWindows.parse(Data(#"{"rate_limits":{}}"#.utf8), updatedAt: written), "empty rate_limits = nil")
        expectNil(UsageWindows.parse(Data("not json".utf8), updatedAt: written), "garbage = nil")
        expectNil(UsageWindows.load(from: URL(fileURLWithPath: "/nonexistent/claudedeck-usage.json")), "missing file = nil")
    }

    suite("UsageWindows — Window reset handling") {
        let w = UsageWindow(usedPercentage: 60, resetsAt: Date(timeIntervalSince1970: 1000))
        expectEqual(w.current(now: Date(timeIntervalSince1970: 500)).usedPercentage, 60, "before reset keeps pct")
        expectEqual(w.current(now: Date(timeIntervalSince1970: 1000)).usedPercentage, 0, "at reset is zero")
        expectEqual(w.current(now: Date(timeIntervalSince1970: 5000)).usedPercentage, 0, "after reset is zero")
        expectEqual(w.secondsUntilReset(now: Date(timeIntervalSince1970: 400)), 600, "seconds until reset")
        expectEqual(w.secondsUntilReset(now: Date(timeIntervalSince1970: 4000)), 0, "never negative")
    }

    suite("UsageWindows — Load from file uses mtime") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-usage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claudedeck-usage.json")
        try? Data(sample.utf8).write(to: url)
        let w = UsageWindows.load(from: url)
        expect(w != nil, "file loads")
        expect(abs((w?.updatedAt.timeIntervalSinceNow ?? 999)) < 60, "updatedAt ~ now (file mtime)")
        try? FileManager.default.removeItem(at: dir)
    }

    suite("ClaudeSession — Registry name / status / version fields") {
        let json = #"{"pid":34588,"sessionId":"0a03","cwd":"/Users/x/GitHub/my-project","startedAt":1793034958255,"version":"2.1.310","kind":"interactive","entrypoint":"cli","name":"my-project-f9","nameSource":"derived","status":"busy"}"#
        let s = try? JSONDecoder().decode(ClaudeSession.self, from: Data(json.utf8))
        expectEqual(s?.name, "my-project-f9", "name decoded")
        expectEqual(s?.nameSource, "derived", "nameSource decoded")
        expectEqual(s?.status, "busy", "status decoded")
        expectEqual(s?.claudeVersion, "2.1.310", "version decoded")
        expectEqual(s?.sessionStatus, .busy, "status enum")
        expectEqual(s?.displayName, "my-project-f9", "display name prefers registry name over folder")
        expectEqual(s?.folderName, "my-project", "folder name still available")

        let old = #"{"pid":1,"sessionId":"old","cwd":"/Users/x/proj","kind":"interactive","entrypoint":"cli"}"#
        let o = try? JSONDecoder().decode(ClaudeSession.self, from: Data(old.utf8))
        expectEqual(o?.sessionStatus, .unknown, "older registry without status = unknown")
        expectEqual(o?.displayName, "proj", "older registry falls back to folder name")

        let weird = #"{"pid":1,"sessionId":"w","cwd":"/p","kind":"interactive","entrypoint":"cli","status":"dancing"}"#
        let wd = try? JSONDecoder().decode(ClaudeSession.self, from: Data(weird.utf8))
        expectEqual(wd?.sessionStatus, .unknown, "unrecognised status value = unknown, not a crash")
    }

    suite("ClaudeSession — sdk-cli entrypoint") {
        let sdk = #"{"pid":1,"sessionId":"s","cwd":"/p","kind":"interactive","entrypoint":"sdk-cli"}"#
        let s = try? JSONDecoder().decode(ClaudeSession.self, from: Data(sdk.utf8))
        expect(s?.isSDK == true, "sdk-cli is SDK")
        expect(s?.isCLI == false, "sdk-cli is not a resumable terminal")
        expectEqual(s?.sourceLabel, "SDK", "SDK label")
        let d = #"{"pid":1,"sessionId":"d","cwd":"/p","kind":"interactive","entrypoint":"claude-desktop"}"#
        let ds = try? JSONDecoder().decode(ClaudeSession.self, from: Data(d.utf8))
        expectEqual(ds?.sourceLabel, "Desktop", "claude-desktop label (value verified in transcripts 2026-10-26)")
    }
}
