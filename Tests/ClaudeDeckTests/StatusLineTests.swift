import Foundation
import ClaudeDeckCore

func runStatusLineTests() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-statusline-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    func assistant(_ input: Int, cacheRead: Int = 0, output: Int = 10) -> String {
        #"{"type":"assistant","message":{"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":0,"output_tokens":\#(output)}}}"#
    }

    suite("StatusLine — Render matches the old quota-watch line") {
        let transcript = tmp.appendingPathComponent("t.jsonl")
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            assistant(0, output: 0),                      // no usage: skipped
            assistant(10_000),
            #"{"type":"user","message":{"content":"tool result with \"usage\" text"}}"#,
            assistant(20_000, cacheRead: 15_000),
            ""
        ]
        try? lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let input = #"{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"cwd":"/Users/x/Github/claude-deck/","transcript_path":"\#(transcript.path)"}"#
        expectEqual(StatusLine.render(Data(input.utf8)), "Opus 5.5 · claude-deck · 35k/turn · 3.5x 🟠", "model · cwd · tokens/turn · waste")

        let noTranscript = #"{"model":{"id":"claude-x"},"cwd":"/tmp"}"#
        expectEqual(StatusLine.render(Data(noTranscript.utf8)), "claude-x · tmp", "falls back to id, no waste without transcript")
        expectEqual(StatusLine.render(Data("garbage".utf8)), "", "bad input = empty line")
    }

    suite("StatusLine — Waste scan reads both ends of a long transcript") {
        let transcript = tmp.appendingPathComponent("long.jsonl")
        var text = assistant(1_000) + "\n"
        let filler = #"{"type":"user","message":{"content":""# + String(repeating: "x", count: 1000) + #""}}"#
        for _ in 0..<1200 { text += filler + "\n" }   // ~1.2 MB, several read chunks
        text += assistant(2_500_000)                   // last line without trailing newline
        try? text.write(to: transcript, atomically: true, encoding: .utf8)
        let w = StatusLine.contextWaste(transcript: transcript)
        expectEqual(w?.first, 1_000, "first turn input")
        expectEqual(w?.last, 2_500_000, "latest turn input")
        expectEqual(StatusLine.formatTokens(2_500_000), "2.5M", "millions format")
        expectEqual(StatusLine.wasteMarker(5.2), " 🔴", "red at 5x")
        expectEqual(StatusLine.wasteMarker(1.9), "", "no marker under 2x")
        expectNil(StatusLine.contextWaste(transcript: tmp.appendingPathComponent("missing.jsonl")), "missing transcript = nil")
    }

    suite("StatusLine — Usage file is written only with rate limits") {
        let url = tmp.appendingPathComponent("usage.json")
        let good = #"{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1793044800},"seven_day":{"used_percentage":30,"resets_at":1793534400}}}"#
        expect(StatusLine.saveUsage(Data(good.utf8), to: url), "writes with rate_limits")
        expectEqual(UsageWindows.load(from: url)?.sevenDay?.usedPercentage, 30, "app reads what was written")
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
        expectEqual(perms, 0o600, "user-only file")
        expect(!StatusLine.saveUsage(Data(#"{"cwd":"/tmp"}"#.utf8), to: url), "no rate_limits: not written")
        expectEqual(UsageWindows.load(from: url)?.sevenDay?.usedPercentage, 30, "last good numbers kept")
    }

    let cli = "/Users/me/.claude/bin/claudedeck"

    suite("StatusLineSetup — Install when no status line is set") {
        let text = "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n"
        let r = try? StatusLineSetup.install(text, cli: cli, replace: false)
        expectEqual(r?.change, .installed, "installed")
        expectEqual(r.map { StatusLineSetup.state(of: $0.text) }, .installed(then: nil), "state is ours")
        expect(r?.text.contains("\"model\": \"opus\",\n  \"env\": {\n    \"A\": \"1\"\n  }") == true, "rest of the file untouched")
        expect(r?.text.hasPrefix("{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": ") == true, "laid out like the file")
        let again = r.flatMap { try? StatusLineSetup.install($0.text, cli: cli, replace: false) }
        expectEqual(again?.change, .unchanged, "second install is a no-op")

        let empty = try? StatusLineSetup.install("{}", cli: cli, replace: false)
        expectEqual(empty.map { StatusLineSetup.state(of: $0.text) }, .installed(then: nil), "installs into an empty object")
    }

    suite("StatusLineSetup — Existing status line is chained, then restored") {
        let own = "/Users/me/.claude/hooks/my line's.sh"
        let text = "{\n  \"a\": 1,\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"\(own)\",\n    \"padding\": 0\n  },\n  \"b\": [1, {\"c\": \"}\"}]\n}\n"
        let r = try? StatusLineSetup.install(text, cli: cli, replace: false)
        expectEqual(r?.change, .wrapped(previous: own), "wrapped")
        expectEqual(r.map { StatusLineSetup.state(of: $0.text) }, .installed(then: own), "chains to the user's command, quote survives")
        let parsed = r.flatMap { try? JSONSerialization.jsonObject(with: Data($0.text.utf8)) as? [String: Any] }
        expectEqual((parsed?["statusLine"] as? [String: Any])?["padding"] as? Int, 0, "other statusLine fields kept")
        expect(r?.text.hasSuffix("\"b\": [1, {\"c\": \"}\"}]\n}\n") == true, "later keys untouched")

        let back = r.flatMap { try? StatusLineSetup.uninstall($0.text) }
        expectEqual(back?.change, .restored(command: own), "uninstall restores")
        expectEqual(back.map { StatusLineSetup.state(of: $0.text) }, .other(command: own), "back to the user's command")

        let switched = r.flatMap { try? StatusLineSetup.install($0.text, cli: cli, replace: true) }
        expectEqual(switched?.change, .replaced(previous: own), "replace on a chained install switches to ours")
        expectEqual(switched.map { StatusLineSetup.state(of: $0.text) }, .installed(then: nil), "now plain")

        let replaced = try? StatusLineSetup.install(text, cli: cli, replace: true)
        expectEqual(replaced?.change, .replaced(previous: own), "replace drops the old command")
        expectEqual(replaced.map { StatusLineSetup.state(of: $0.text) }, .installed(then: nil), "plain ClaudeDeck line")
    }

    suite("StatusLineSetup — Uninstall removes a plain entry cleanly") {
        let middle = "{\n  \"a\": 1,\n  \"statusLine\": {\"type\": \"command\", \"command\": \"'\(cli)' statusline\"},\n  \"b\": 2\n}\n"
        expectEqual((try? StatusLineSetup.uninstall(middle))?.text, "{\n  \"a\": 1,\n  \"b\": 2\n}\n", "middle key removed")
        let last = "{\n  \"a\": 1,\n  \"statusLine\": {\"type\": \"command\", \"command\": \"'\(cli)' statusline\"}\n}\n"
        expectEqual((try? StatusLineSetup.uninstall(last))?.text, "{\n  \"a\": 1\n}\n", "last key removed with its comma")
        let only = "{\"statusLine\": {\"type\": \"command\", \"command\": \"claudedeck statusline\"}}"
        expectEqual((try? StatusLineSetup.uninstall(only))?.text, "{}", "only key removed")
        do {
            _ = try StatusLineSetup.uninstall("{\"a\": 1}")
            expect(false, "uninstall without ours must throw")
        } catch {
            expectEqual(error as? StatusLineSetup.SetupError, .notInstalled, "not installed error")
        }
    }

    suite("StatusLineSetup — Refuses what it cannot edit safely") {
        do {
            _ = try StatusLineSetup.install("[1, 2]", cli: cli, replace: false)
            expect(false, "array must throw")
        } catch {
            expectEqual(error as? StatusLineSetup.SetupError, .notAnObject, "not an object")
        }
        do {
            _ = try StatusLineSetup.install("{\"statusLine\": {\"type\": \"static\"}}", cli: cli, replace: false)
            expect(false, "entry without command must throw")
        } catch {
            expectEqual(error as? StatusLineSetup.SetupError, .unrecognised, "unrecognised entry")
        }
        expectEqual(StatusLineSetup.shellUnquote(StatusLineSetup.shellQuote("it's")), "it's", "quote round trip")
    }

    suite("StatusLineSetup — Apply backs up and writes through a symlink") {
        let real = tmp.appendingPathComponent("dotfiles-settings.json")
        let link = tmp.appendingPathComponent("settings.json")
        try? "{\n  \"a\": 1\n}\n".write(to: real, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let r = try? StatusLineSetup.apply(at: link) { try StatusLineSetup.install($0, cli: cli, replace: false) }
        expectEqual(r?.change, .installed, "applied")
        expect(r?.backup.map { FileManager.default.fileExists(atPath: $0.path) } == true, "backup written")
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        expectEqual(dest, real.path, "symlink kept")
        let written = try? String(contentsOf: real, encoding: .utf8)
        expectEqual(written.map { StatusLineSetup.state(of: $0) }, .installed(then: nil), "target file edited")
        let again = try? StatusLineSetup.apply(at: link) { try StatusLineSetup.install($0, cli: cli, replace: false) }
        expectEqual(again?.change, .unchanged, "no rewrite when already installed")
        expectNil(again?.backup, "no backup when unchanged")
    }
}
