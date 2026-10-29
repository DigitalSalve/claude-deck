import Foundation
import ClaudeDeckCore

private func makeTempProjects() -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("prompt-reader-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func writeSessionFile(
    projectsDir: URL,
    project: String,
    sessionId: String,
    lines: [String]
) {
    let dir = projectsDir.appendingPathComponent(project)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("\(sessionId).jsonl")
    let body = lines.joined(separator: "\n") + "\n"
    try? body.write(to: file, atomically: true, encoding: .utf8)
}

private func userLine(content: Any) -> String {
    let obj: [String: Any] = [
        "type": "user",
        "message": ["content": content]
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

private func systemLine() -> String {
    let obj: [String: Any] = ["type": "system", "content": "boot"]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

func runSessionPromptReaderTests() {
    suite("SessionPromptReader: plain string content") {
        let dir = makeTempProjects()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = UUID().uuidString
        writeSessionFile(projectsDir: dir, project: "-proj", sessionId: sid, lines: [
            systemLine(),
            userLine(content: "Fix memory leak in quota reporting")
        ])
        // Use a dedicated reader instance per suite to avoid cross-test cache pollution.
        let prompt = SessionPromptReader.shared.firstPrompt(sessionId: sid, projectsDir: dir)
        expectEqual(prompt, "Fix memory leak in quota reporting", "extracted first user prompt")
    }

    suite("SessionPromptReader: array content") {
        let dir = makeTempProjects()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = UUID().uuidString
        let content: [[String: Any]] = [
            ["type": "text", "text": "Check MyGoPHub production status"]
        ]
        writeSessionFile(projectsDir: dir, project: "-proj", sessionId: sid, lines: [
            userLine(content: content)
        ])
        let prompt = SessionPromptReader.shared.firstPrompt(sessionId: sid, projectsDir: dir)
        expectEqual(prompt, "Check MyGoPHub production status", "extracted from array content")
    }

    suite("SessionPromptReader: skips scheduled-task wrapper") {
        let dir = makeTempProjects()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = UUID().uuidString
        writeSessionFile(projectsDir: dir, project: "-proj", sessionId: sid, lines: [
            userLine(content: "<scheduled-task name=\"dream\">auto-run</scheduled-task>"),
            userLine(content: "What is the current quota usage?")
        ])
        let prompt = SessionPromptReader.shared.firstPrompt(sessionId: sid, projectsDir: dir)
        expectEqual(prompt, "What is the current quota usage?", "skipped wrapper, got real prompt")
    }

    suite("SessionPromptReader: truncates long prompts") {
        let dir = makeTempProjects()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = UUID().uuidString
        let long = String(repeating: "x ", count: 100) // 200 chars
        writeSessionFile(projectsDir: dir, project: "-proj", sessionId: sid, lines: [
            userLine(content: long)
        ])
        let prompt = SessionPromptReader.shared.firstPrompt(sessionId: sid, projectsDir: dir)
        expect(prompt != nil, "got a prompt")
        expect((prompt?.count ?? 0) <= 81, "truncated to <=81 chars (with ellipsis)")
        expect(prompt?.hasSuffix("…") ?? false, "truncation marker appended")
    }

    suite("SessionPromptReader: returns nil when no user message") {
        let dir = makeTempProjects()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = UUID().uuidString
        writeSessionFile(projectsDir: dir, project: "-proj", sessionId: sid, lines: [
            systemLine()
        ])
        let prompt = SessionPromptReader.shared.firstPrompt(sessionId: sid, projectsDir: dir)
        expectNil(prompt, "no user line = nil prompt")
    }

    suite("SessionPromptReader: returns nil when session file missing") {
        let dir = makeTempProjects()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompt = SessionPromptReader.shared.firstPrompt(
            sessionId: "nonexistent-session-id", projectsDir: dir
        )
        expectNil(prompt, "missing file = nil prompt")
    }
}
