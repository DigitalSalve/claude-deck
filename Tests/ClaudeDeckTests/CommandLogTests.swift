import Foundation
import ClaudeDeckCore

func runCommandLogTests() {
    let spawn = "2026-10-28T18:11:23Z ok  spawn caller=115beb75 target=56ca79b1 dir=/Users/x/My Repo agent=lane-a mode=tab prompt=yes :: session started in /Users/x: c3 (56ca79b1)"
    let denied = "2026-10-28T18:12:00Z ERR compact caller=aaa target=bbb :: this session does not hold the orchestrator role"
    let ping = "2026-10-28T20:21:30Z ok  ping caller=- target=- :: ClaudeDeck is running :: still"

    suite("CommandLog — parse log lines") {
        let s = CommandLog.parse(spawn, id: 1)
        expectEqual(s?.verb, "spawn", "verb")
        expectEqual(s?.ok, true, "ok status")
        expectEqual(s?.caller, "115beb75", "caller")
        expectEqual(s?.target, "56ca79b1", "target")
        expectEqual(s?.detail, "dir=/Users/x/My Repo agent=lane-a mode=tab prompt=yes", "spawn detail kept, spaces in dir survive")
        expectEqual(s?.message, "session started in /Users/x: c3 (56ca79b1)", "message")
        let d = CommandLog.parse(denied, id: 2)
        expectEqual(d?.ok, false, "ERR status")
        expectEqual(d?.detail, "", "no detail")
        let p = CommandLog.parse(ping, id: 3)
        expectNil(p?.caller, "dash caller = nil (human shell)")
        expectNil(p?.target, "dash target = nil")
        expectEqual(p?.message, "ClaudeDeck is running :: still", "separator inside message kept")
        expectNil(CommandLog.parse("garbage line", id: 4), "garbage rejected")
        expectNil(CommandLog.parse("notadate ok ping caller=- target=- :: x", id: 5), "bad date rejected")
    }

    suite("CommandLog — load newest first with limit") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-cmdlog-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try? ([spawn, "junk", denied, ping].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let all = CommandLog.load(url)
        expectEqual(all.map(\.verb), ["ping", "compact", "spawn"], "newest first, junk skipped")
        expectEqual(CommandLog.load(url, limit: 1).map(\.verb), ["ping"], "limit")
        expectEqual(CommandLog.load(url.appendingPathExtension("missing")).count, 0, "missing file = empty")
    }

    suite("PendingCommands — queued badge lifecycle") {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func entry(_ verb: String, _ target: String, ok: Bool = true, at: Date = t0) -> CommandLogEntry {
            CommandLogEntry(id: 0, at: at, ok: ok, verb: verb, caller: "c", target: target, detail: "", message: "")
        }
        var p = PendingCommands()
        p.note(entry("compact", "s1"))
        p.note(entry("clear", "s2", ok: false))
        p.note(entry("spawn", "s3"))
        expectEqual(p.verb(for: "s1"), "compact", "ok compact is queued")
        expectNil(p.verb(for: "s2"), "denied request not queued")
        expectNil(p.verb(for: "s3"), "spawn not queued")

        p.observe(["s1": true], now: t0.addingTimeInterval(3))
        expectEqual(p.verb(for: "s1"), "compact", "idle before the typing delay: still queued")
        p.observe(["s1": false], now: t0.addingTimeInterval(60))
        expectEqual(p.verb(for: "s1"), "compact", "busy: waiting for idle")
        p.observe(["s1": true], now: t0.addingTimeInterval(70))
        expectNil(p.verb(for: "s1"), "idle after the delay: landed")

        p.note(entry("clear", "s4"))
        p.observe([:], now: t0.addingTimeInterval(20))
        expectNil(p.verb(for: "s4"), "session gone: dropped")

        p.note(entry("compact", "s5"))
        p.observe(["s5": false], now: t0.addingTimeInterval(PendingCommands.timeout + 1))
        expectNil(p.verb(for: "s5"), "timed out")

        p.note(entry("compact", "s6", at: t0.addingTimeInterval(100)))
        p.note(entry("clear", "s6", at: t0))
        expectEqual(p.verb(for: "s6"), "compact", "older entry does not replace newer")
    }
}
