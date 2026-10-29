import Foundation
import ClaudeDeckCore

func runClaudeSessionTests() {
    suite("ClaudeSession — JSON Decoding") {
        let full = """
        {"pid":1234,"sessionId":"abc-123","cwd":"/Users/test/project","startedAt":1700000000000,"kind":"interactive","entrypoint":"cli"}
        """
        if let s = try? JSONDecoder().decode(ClaudeSession.self, from: full.data(using: .utf8)!) {
            expectEqual(s.id, "abc-123", "id decoded from sessionId key")
            expectEqual(s.pid, 1234, "pid decoded")
            expectEqual(s.cwd, "/Users/test/project", "cwd decoded")
            expectEqual(s.startedAt, 1700000000000, "startedAt decoded")
            expectEqual(s.entrypoint, "cli", "entrypoint decoded")
        } else {
            expect(false, "full session decode should not throw")
        }

        let minimal = """
        {"sessionId":"xyz-456","cwd":"/tmp"}
        """
        if let s = try? JSONDecoder().decode(ClaudeSession.self, from: minimal.data(using: .utf8)!) {
            expectEqual(s.id, "xyz-456", "minimal id")
            expectNil(s.pid, "pid nil when missing")
            expectNil(s.startedAt, "startedAt nil when missing")
        } else {
            expect(false, "minimal session decode should not throw")
        }
    }

    suite("ClaudeSession — Source Type") {
        let cli     = makeSession(entrypoint: "cli")
        let desktop = makeSession(entrypoint: "claude-desktop")
        let web     = makeSession(entrypoint: "web")
        let webAlt  = makeSession(entrypoint: "claude-web")
        let nilEP   = makeSession(entrypoint: nil)

        expect(cli.isCLI && !cli.isDesktop && !cli.isWeb, "cli entrypoint is CLI")
        expectEqual(cli.sourceLabel, "Terminal", "CLI sourceLabel")
        expect(desktop.isDesktop && !desktop.isCLI, "claude-desktop is Desktop")
        expectEqual(desktop.sourceLabel, "Desktop", "Desktop sourceLabel")
        expect(web.isWeb && !web.isCLI, "web is Web")
        expect(webAlt.isWeb, "claude-web is Web")
        expect(nilEP.isCLI, "nil entrypoint defaults to CLI")
    }

    suite("ClaudeSession — Display Name") {
        let s = makeSession(cwd: "/Users/alex/projects/my-app")
        expectEqual(s.displayName, "my-app", "displayName uses cwd last component")

        var s2 = makeSession(cwd: "/Users/alex/projects/my-app")
        s2.resolvedName = "Custom"
        expectEqual(s2.displayName, "Custom", "displayName uses resolvedName when set")
    }

    suite("ClaudeSession — startDate") {
        let epochMs: Double = 1700000000000
        let s = makeSession(startedAt: epochMs)
        let expected = Date(timeIntervalSince1970: epochMs / 1000)
        expectEqual(s.startDate, expected, "startDate converts epoch ms")
        expectNil(makeSession(startedAt: nil).startDate, "startDate nil when missing")
    }

    suite("ClaudeSession — isActive") {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let live = """
        {"pid":\(pid),"sessionId":"live","cwd":"/tmp"}
        """
        if let s = try? JSONDecoder().decode(ClaudeSession.self, from: live.data(using: .utf8)!) {
            expect(s.isActive, "current process is active")
        }

        let dead = """
        {"pid":99999999,"sessionId":"dead","cwd":"/tmp"}
        """
        if let s = try? JSONDecoder().decode(ClaudeSession.self, from: dead.data(using: .utf8)!) {
            expect(!s.isActive, "bogus PID is not active")
        }

        expect(!makeSession(pid: nil).isActive, "nil pid is not active")
    }
}

private func makeSession(
    id: String = "test", pid: Int? = nil, cwd: String = "/tmp",
    startedAt: Double? = nil, entrypoint: String? = nil
) -> ClaudeSession {
    var fields = ["\"sessionId\":\"\(id)\"", "\"cwd\":\"\(cwd)\""]
    if let pid { fields.append("\"pid\":\(pid)") }
    if let ts = startedAt { fields.append("\"startedAt\":\(ts)") }
    if let ep = entrypoint { fields.append("\"entrypoint\":\"\(ep)\"") }
    return try! JSONDecoder().decode(ClaudeSession.self,
                                    from: "{\(fields.joined(separator: ","))}".data(using: .utf8)!)
}
