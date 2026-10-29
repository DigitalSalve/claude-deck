import Foundation
import ClaudeDeckCore

// MARK: - Fixtures

private func makeTempClaudeDir() -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudedeck-test-\(UUID().uuidString)")
    let projects = base.appendingPathComponent("projects")
    let sessions = base.appendingPathComponent("sessions")
    try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    return base
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// ISO-8601 timestamp for "now" so default test fixtures sit inside the
/// 7-day cutoff regardless of when the suite runs. Pinning a literal date
/// here made the period-cutoff tests flip to failing 7 days after that date.
private let recentTimestamp: String = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}()

/// Produce a minimal JSONL assistant turn line.
private func turnLine(
    input: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    output: Int,
    model: String = "claude-opus-4-6",
    ts: String = recentTimestamp
) -> String {
    let usage: [String: Any] = [
        "input_tokens": input,
        "cache_read_input_tokens": cacheRead,
        "cache_creation_input_tokens": cacheWrite,
        "output_tokens": output
    ]
    let message: [String: Any] = ["model": model, "usage": usage]
    let obj: [String: Any] = [
        "type": "assistant",
        "message": message,
        "timestamp": ts
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

private func userLine(content: String = "hello") -> String {
    let obj: [String: Any] = ["type": "user", "message": ["content": content]]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

private func writeSession(
    claudeDir: URL,
    project: String,
    sessionId: String,
    lines: [String]
) -> URL {
    let dir = claudeDir
        .appendingPathComponent("projects")
        .appendingPathComponent(project)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("\(sessionId).jsonl")
    let body = lines.joined(separator: "\n") + "\n"
    try! body.write(to: file, atomically: true, encoding: .utf8)
    return file
}

/// Write a subagent JSONL at the canonical
/// `projects/{project}/{parentId}/subagents/agent-{id}.jsonl` location.
private func writeSubagent(
    claudeDir: URL,
    project: String,
    parentSessionId: String,
    agentId: String,
    lines: [String]
) -> URL {
    let dir = claudeDir
        .appendingPathComponent("projects")
        .appendingPathComponent(project)
        .appendingPathComponent(parentSessionId)
        .appendingPathComponent("subagents")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("agent-\(agentId).jsonl")
    let body = lines.joined(separator: "\n") + "\n"
    try! body.write(to: file, atomically: true, encoding: .utf8)
    return file
}

private func appendToSession(_ file: URL, lines: [String]) {
    let body = lines.joined(separator: "\n") + "\n"
    let handle = try! FileHandle(forWritingTo: file)
    handle.seekToEndOfFile()
    handle.write(body.data(using: .utf8)!)
    try? handle.close()
}

// MARK: - Tests

func runQuotaAnalyzerTests() {
    suite("QuotaAnalyzer: basic aggregation") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        _ = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "session-a",
            lines: [
                turnLine(input: 1000, cacheRead: 500, output: 200),
                turnLine(input: 1200, cacheRead: 800, output: 300),
                turnLine(input: 1500, cacheRead: 1200, output: 150)
            ]
        )

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let report = analyzer.analyze(period: .allTime)

        expectEqual(report.sessions.count, 1, "one session reported")
        let s = report.sessions.first!
        expectEqual(s.turns, 3, "turns counted correctly")
        expectEqual(s.id, "session-a", "session id matches filename")
        expectEqual(s.baseInputPerTurn, 1500, "base = first turn total input+cache")
        expectEqual(s.currentInputPerTurn, 2700, "current = last turn total input+cache")
        expectEqual(s.totalOutputTokens, 650, "output tokens summed")
    }

    suite("QuotaAnalyzer: prefilter skips non-assistant lines") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        _ = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "mixed",
            lines: [
                userLine(content: "first user msg"),
                turnLine(input: 1000, output: 100),
                userLine(content: "second user msg"),
                userLine(content: "tool result here"),
                turnLine(input: 1100, output: 120)
            ]
        )

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let report = analyzer.analyze(period: .allTime)
        expectEqual(report.sessions.count, 1, "session found despite noise")
        expectEqual(report.sessions.first?.turns, 2, "only assistant turns counted")
    }

    suite("QuotaAnalyzer: cache reuse on unchanged files") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        _ = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "stable",
            lines: [turnLine(input: 1000, output: 200)]
        )

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let first = analyzer.analyze(period: .allTime)
        let second = analyzer.analyze(period: .allTime)
        expectEqual(first.sessions.count, 1, "first analyze returns session")
        expectEqual(second.sessions.count, 1, "second analyze returns session")
        expectEqual(
            first.sessions.first?.totalTokens,
            second.sessions.first?.totalTokens,
            "identical totals across runs"
        )
    }

    suite("QuotaAnalyzer: incremental parse on append") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        let file = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "growing",
            lines: [turnLine(input: 1000, output: 100)]
        )

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let first = analyzer.analyze(period: .allTime)
        expectEqual(first.sessions.first?.turns, 1, "first analyze: 1 turn")

        // Must bump mtime so the analyzer treats the file as changed.
        // Filesystem mtime resolution can be 1s — sleep briefly.
        Thread.sleep(forTimeInterval: 1.1)
        appendToSession(file, lines: [
            turnLine(input: 1500, output: 200),
            turnLine(input: 2000, output: 250)
        ])

        let second = analyzer.analyze(period: .allTime)
        expectEqual(second.sessions.first?.turns, 3, "after append: 3 turns")
        expectEqual(
            second.sessions.first?.baseInputPerTurn,
            1000,
            "base preserved from first parse"
        )
    }

    suite("QuotaAnalyzer: cache persists across instances") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        _ = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "persisted",
            lines: [
                turnLine(input: 1000, output: 100),
                turnLine(input: 1200, output: 150)
            ]
        )

        let a1 = QuotaAnalyzer(claudeDir: dir)
        let r1 = a1.analyze(period: .allTime)
        expectEqual(r1.sessions.first?.turns, 2, "first instance: 2 turns")
        a1.persistCache()

        let cacheFile = dir.appendingPathComponent("claude-deck-cache.json")
        expect(
            FileManager.default.fileExists(atPath: cacheFile.path),
            "cache file written to disk"
        )

        // New instance hydrates from disk.
        let a2 = QuotaAnalyzer(claudeDir: dir)
        let r2 = a2.analyze(period: .allTime)
        expectEqual(r2.sessions.first?.turns, 2, "second instance: 2 turns from cache")
    }

    suite("QuotaAnalyzer: cache invalidates on file truncation") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        let file = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "truncated",
            lines: [
                turnLine(input: 1000, output: 100),
                turnLine(input: 1500, output: 200)
            ]
        )
        let analyzer = QuotaAnalyzer(claudeDir: dir)
        _ = analyzer.analyze(period: .allTime)

        Thread.sleep(forTimeInterval: 1.1)
        // Rewrite file smaller — simulates rotation or user truncation.
        try! (turnLine(input: 500, output: 50) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let report = analyzer.analyze(period: .allTime)
        expectEqual(
            report.sessions.first?.turns, 1,
            "truncated file re-parses from scratch"
        )
        expectEqual(
            report.sessions.first?.totalOutputTokens, 50,
            "totals reflect new content only"
        )
    }

    suite("QuotaAnalyzer: period cutoff filters old sessions") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        _ = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "recent",
            lines: [turnLine(input: 1000, output: 100)]
        )

        // Old session — mtime backdated via FileManager.
        let oldFile = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "ancient",
            lines: [turnLine(
                input: 1000,
                output: 100,
                ts: "2020-01-01T00:00:00.000Z"
            )]
        )
        let ancient = Date().addingTimeInterval(-60 * 24 * 3600) // 60 days ago
        try? FileManager.default.setAttributes(
            [.modificationDate: ancient], ofItemAtPath: oldFile.path
        )

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let weekReport = analyzer.analyze(period: .sevenDays)
        expectEqual(weekReport.sessions.count, 1, "7d: only recent session")

        let allReport = analyzer.analyze(period: .allTime)
        expectEqual(allReport.sessions.count, 2, "all: both sessions")
    }

    suite("QuotaAnalyzer: subagents counted and attributed to parent") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        let parentId = "parent-sess"
        _ = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: parentId,
            lines: [
                turnLine(input: 1000, output: 200),
                turnLine(input: 1200, output: 250)
            ]
        )
        _ = writeSubagent(
            claudeDir: dir,
            project: "-Users-test-proj",
            parentSessionId: parentId,
            agentId: "abc123",
            lines: [
                turnLine(input: 100, cacheWrite: 9000, output: 50, model: "claude-haiku-4-5"),
                turnLine(input: 50, cacheRead: 9000, output: 40, model: "claude-haiku-4-5")
            ]
        )
        _ = writeSubagent(
            claudeDir: dir,
            project: "-Users-test-proj",
            parentSessionId: parentId,
            agentId: "def456",
            lines: [
                turnLine(input: 80, cacheWrite: 7000, output: 30, model: "claude-haiku-4-5")
            ]
        )

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let report = analyzer.analyze(period: .allTime)

        expectEqual(report.sessions.count, 3, "parent + 2 subagents all counted")
        expectEqual(report.rootSessions.count, 1, "one top-level session")
        expectEqual(report.rootSessions.first?.id, parentId, "root is parent session")
        expectEqual(report.rootSessions.first?.isSubagent, false, "parent not tagged subagent")

        let kids = report.subagents(of: parentId)
        expectEqual(kids.count, 2, "two subagents linked to parent")
        expect(kids.allSatisfy { $0.isSubagent }, "both kids tagged subagent")
        expect(
            kids.allSatisfy { $0.parentSessionId == parentId },
            "both kids carry parent session id"
        )
        expectEqual(
            report.orphanSubagents.count, 0,
            "no orphans when parent is in report"
        )

        // Token totals include subagent tokens — this is the core fix.
        // Parent: (1000+1200) input + (200+250) output = 2650
        // Sub A:  (100+9000+50+9000) + (50+40) = 18240
        // Sub B:  (80+7000) + 30 = 7110
        // Total = 28000
        expectEqual(report.totalTokens, 28000, "totals include subagent tokens")
    }

    suite("QuotaAnalyzer: orphan subagents surface when parent outside period") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        let parentId = "old-parent"
        let parentFile = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: parentId,
            lines: [turnLine(input: 1000, output: 100, ts: "2020-01-01T00:00:00.000Z")]
        )
        let subagent = writeSubagent(
            claudeDir: dir,
            project: "-Users-test-proj",
            parentSessionId: parentId,
            agentId: "still-recent",
            lines: [turnLine(input: 100, cacheWrite: 5000, output: 50)]
        )
        // Backdate parent so 7d cutoff excludes it, subagent stays recent.
        let ancient = Date().addingTimeInterval(-60 * 24 * 3600)
        try? FileManager.default.setAttributes(
            [.modificationDate: ancient], ofItemAtPath: parentFile.path
        )
        _ = subagent

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let report = analyzer.analyze(period: .sevenDays)

        expectEqual(report.rootSessions.count, 0, "parent excluded by cutoff")
        expectEqual(
            report.orphanSubagents.count, 1,
            "subagent surfaces as orphan so its tokens aren't invisible"
        )
    }

    suite("QuotaAnalyzer: cached carry is not persisted to disk") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        // Write a turn without a trailing newline so parseFile leaves bytes
        // in `carry` that historically got persisted to disk base64-encoded.
        let projectsDir = dir.appendingPathComponent("projects")
            .appendingPathComponent("-Users-test-proj")
        try? FileManager.default.createDirectory(
            at: projectsDir, withIntermediateDirectories: true
        )
        let file = projectsDir.appendingPathComponent("no-newline.jsonl")
        let body = turnLine(input: 1000, output: 100) + "\n"
            + turnLine(input: 1200, output: 150)   // no trailing \n
        try! body.write(to: file, atomically: true, encoding: .utf8)

        let a1 = QuotaAnalyzer(claudeDir: dir)
        _ = a1.analyze(period: .allTime)
        a1.persistCache()

        let cacheFile = dir.appendingPathComponent("claude-deck-cache.json")
        let cacheData = try? Data(contentsOf: cacheFile)
        expect(cacheData != nil, "cache file written")
        let cacheText = String(data: cacheData ?? Data(), encoding: .utf8) ?? ""
        expect(
            !cacheText.contains("\"carry\""),
            "carry field excluded from serialized cache"
        )
    }

    suite("QuotaAnalyzer: handles corrupt lines gracefully") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        _ = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "corrupt",
            lines: [
                turnLine(input: 1000, output: 100),
                "{not valid json",
                "",
                turnLine(input: 1200, output: 150)
            ]
        )

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let report = analyzer.analyze(period: .allTime)
        expectEqual(report.sessions.count, 1, "session parsed despite garbage")
        expectEqual(report.sessions.first?.turns, 2, "valid turns counted")
    }

    suite("QuotaAnalyzer: sessionHistory totals + message count") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        let file = writeSession(
            claudeDir: dir,
            project: "-Users-test-proj",
            sessionId: "hist",
            lines: [
                userLine(content: "hi"),
                turnLine(input: 100, cacheRead: 10, cacheWrite: 5, output: 20),
                userLine(content: "again"),
                turnLine(input: 200, output: 30)
            ]
        )

        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let h = analyzer.sessionHistory(for: file, projectPath: "-Users-test-proj")
        expectEqual(h?.id, "hist", "id from filename")
        expectEqual(h?.messageCount, 4, "user + assistant lines counted")
        expectEqual(h?.totalInputTokens, 300, "input summed")
        expectEqual(h?.totalCacheReadTokens, 10, "cache read summed")
        expectEqual(h?.totalCacheWriteTokens, 5, "cache write summed")
        expectEqual(h?.totalOutputTokens, 50, "output summed")
        expect(h?.firstActivity != nil, "first activity set")
    }

    suite("QuotaAnalyzer: sessionHistory reads only appended bytes") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        let first = turnLine(input: 100, output: 10)
        let file = writeSession(
            claudeDir: dir, project: "-Users-test-proj", sessionId: "inc",
            lines: [first]
        )
        let analyzer = QuotaAnalyzer(claudeDir: dir)
        _ = analyzer.sessionHistory(for: file, projectPath: "p")

        // Blank out the already-parsed line in place (same length). A full
        // re-read would lose its tokens; an incremental read keeps them.
        let handle = try! FileHandle(forWritingTo: file)
        handle.write(Data(repeating: 0x20, count: first.utf8.count))
        try? handle.close()
        appendToSession(file, lines: [turnLine(input: 50, output: 5)])

        let h = analyzer.sessionHistory(for: file, projectPath: "p")
        expectEqual(h?.totalOutputTokens, 15, "old tokens kept, new tokens added")
        expectEqual(h?.messageCount, 2, "message count incremental")
    }

    suite("QuotaAnalyzer: firstOutputTimestamp ignores messages before cutoff") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let old = now.addingTimeInterval(-6 * 24 * 3600 - 7200)
        let inWindow = now.addingTimeInterval(-2 * 24 * 3600)
        let file = writeSession(
            claudeDir: dir, project: "-Users-test-proj", sessionId: "wk",
            lines: [
                turnLine(input: 1, output: 5, model: "claude-sonnet-4-6", ts: f.string(from: old)),
                turnLine(input: 1, output: 0, model: "claude-sonnet-4-6", ts: f.string(from: inWindow.addingTimeInterval(-3600))),
                turnLine(input: 1, output: 5, model: "claude-sonnet-4-6", ts: f.string(from: inWindow))
            ]
        )
        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let cutoff = now.addingTimeInterval(-6 * 24 * 3600)
        let hit = analyzer.firstOutputTimestamp(for: file, since: cutoff)
        expect(hit != nil, "anchor found")
        expect(abs((hit?.timestamp ?? .distantPast).timeIntervalSince(inWindow)) < 0.01,
               "anchor = first output message inside window (zero-output skipped)")
        expect(hit?.model?.contains("sonnet") == true, "model reported")
    }

    suite("QuotaAnalyzer: oversized line doesn't swallow neighbouring turns") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }

        // 1.5 MB user line (pasted screenshot) between two assistant turns,
        // with the second turn landing in the same read chunk as its tail.
        let file = writeSession(
            claudeDir: dir, project: "-Users-test-proj", sessionId: "big",
            lines: [
                turnLine(input: 100, output: 10),
                // Literal JSON: Claude Code writes "type" before "message".
                "{\"type\":\"user\",\"message\":{\"content\":\"" + String(repeating: "A", count: 1_500_000) + "\"}}",
                turnLine(input: 100, output: 20),
                userLine(content: "after")
            ]
        )
        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let report = analyzer.analyze(period: .allTime)
        expectEqual(report.sessions.first?.turns, 2, "both turns counted")
        expectEqual(report.sessions.first?.totalOutputTokens, 30, "both outputs counted")
        let h = analyzer.sessionHistory(for: file, projectPath: "p")
        expectEqual(h?.messageCount, 4, "oversized user line still counted once")
    }

    suite("QuotaAnalyzer: thinking tokens and web tool calls (DS-39)") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }
        let line = { (out: Int, think: Int, search: Int, fetch: Int) -> String in
            """
            {"type":"assistant","timestamp":"\(recentTimestamp)","message":{"model":"claude-fable-5-1","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":\(out),"output_tokens_details":{"thinking_tokens":\(think)},"server_tool_use":{"web_search_requests":\(search),"web_fetch_requests":\(fetch)}}}}
            """
        }
        _ = writeSession(
            claudeDir: dir, project: "-Users-test-proj", sessionId: "think",
            lines: [line(100, 40, 2, 1), line(50, 10, 0, 3), turnLine(input: 10, output: 20)]
        )
        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let report = analyzer.analyze(period: .allTime)
        let s = report.sessions.first { $0.id == "think" }
        expectEqual(s?.totalOutputTokens, 170, "output totals include every turn")
        expectEqual(s?.thinkingTokens, 50, "thinking tokens summed; turns without details add 0")
        expectEqual(s?.visibleOutputTokens, 120, "visible = output - thinking")
        expectEqual(s?.webSearchRequests, 2, "web searches summed")
        expectEqual(s?.webFetchRequests, 4, "web fetches summed")
        expectEqual(report.totalThinkingTokens, 50, "report aggregates thinking")
        expectEqual(report.totalWebRequests, 6, "report aggregates web calls")
    }

    suite("SessionPromptReader: ai-title and last-prompt from the tail (DS-38)") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }
        let file = writeSession(
            claudeDir: dir, project: "-Users-test-proj", sessionId: "titled",
            lines: [
                turnLine(input: 1, output: 1),
                #"{"type":"ai-title","aiTitle":"First title","sessionId":"titled"}"#,
                #"{"type":"last-prompt","lastPrompt":"fix the   build\nplease","sessionId":"titled"}"#,
                turnLine(input: 1, output: 1),
                #"{"type":"ai-title","aiTitle":"  Freeway v2 MCP OAuth flow ","sessionId":"titled"}"#,
                #"{"type":"last-prompt","lastPrompt":"now ship it","sessionId":"titled"}"#,
            ]
        )
        let r = SessionPromptReader.shared.titleAndLastPrompt(for: file, cacheKey: "titled-\(UUID())")
        expectEqual(r.title, "Freeway v2 MCP OAuth flow", "newest title wins, trimmed")
        expectEqual(r.lastPrompt, "now ship it", "newest last-prompt wins")

        let partialText = [
            #"itle","aiTitle":"cut off"}"#,
            #"{"type":"ai-title","aiTitle":"Whole"}"#,
            "{\"type\":\"last-prompt\",\"lastPrompt\":\"a  b\\tc\"}",
            "",
        ].joined(separator: "\n")
        let partial = SessionPromptReader.scanTail(data: Data(partialText.utf8), skipFirstPartialLine: true)
        expectEqual(partial.title, "Whole", "first partial line skipped when seeking mid-file")
        expectEqual(partial.lastPrompt, "a b c", "whitespace collapsed")

        let none = SessionPromptReader.scanTail(data: Data("{\"type\":\"user\",\"message\":{}}\n".utf8), skipFirstPartialLine: false)
        expectNil(none.title, "no title record = nil")
        expectNil(none.lastPrompt, "no last-prompt record = nil")

        let empty = SessionPromptReader.shared.titleAndLastPrompt(
            sessionId: "missing", projectsDir: dir.appendingPathComponent("projects"))
        expectNil(empty.title, "unknown session = nil title")
    }

    suite("QuotaAnalyzer: custom date range bounds both ends") {
        let dir = makeTempClaudeDir()
        defer { cleanup(dir) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let d10 = now.addingTimeInterval(-10 * 86400), d5 = now.addingTimeInterval(-5 * 86400), d1 = now.addingTimeInterval(-1 * 86400)
        _ = writeSession(claudeDir: dir, project: "-Users-test-proj", sessionId: "old",
                         lines: [turnLine(input: 10, output: 5, ts: f.string(from: d10))])
        _ = writeSession(claudeDir: dir, project: "-Users-test-proj", sessionId: "mid",
                         lines: [turnLine(input: 10, output: 5, ts: f.string(from: d5))])
        _ = writeSession(claudeDir: dir, project: "-Users-test-proj", sessionId: "new",
                         lines: [turnLine(input: 10, output: 5, ts: f.string(from: d1))])
        let analyzer = QuotaAnalyzer(claudeDir: dir)
        let range = DateInterval(start: now.addingTimeInterval(-7 * 86400), end: now.addingTimeInterval(-3 * 86400))
        let r = analyzer.analyze(period: .custom, customHours: 4, customRange: range)
        let ids = Set(r.sessions.map { $0.id })
        expect(ids == ["mid"], "only the session inside the range is reported: \(ids)")
        expect(r.periodLabel.contains("–"), "label shows the date range")
        let hoursOnly = analyzer.analyze(period: .custom, customHours: 48)
        expectEqual(Set(hoursOnly.sessions.map { $0.id }), ["new"], "without a range, custom hours still apply")
        let open = analyzer.analyze(period: .custom, customHours: 4, customRange: DateInterval(start: d10.addingTimeInterval(-3600), end: now))
        expectEqual(open.sessions.count, 3, "a range reaching now includes everything since its start")
    }
}
