import Foundation

/// Reads the first user prompt from a session's JSONL transcript and caches it
/// by sessionId. First-prompt text never changes for a given session, so the
/// cache lives for the lifetime of the process.
package final class SessionPromptReader {
    package static let shared = SessionPromptReader()

    private let cacheLock = NSLock()
    private var cache: [String: String] = [:]

    /// Only read the head of the JSONL — first user message appears almost
    /// always in the first few kilobytes. 32 KB is generous.
    private let readBudget = 32 * 1024

    /// Tail budget for the title / last-prompt scan. `ai-title` and
    /// `last-prompt` records are rewritten as the session goes, so the
    /// newest ones sit near the end of the file.
    private let tailBudget = 96 * 1024

    private struct TailInfo { let mtime: Date; let size: Int; let title: String?; let lastPrompt: String? }
    private var tailCache: [String: TailInfo] = [:]

    private init() {}

    /// Claude Code's generated session title (`ai-title` record) and the
    /// most recent user prompt (`last-prompt` record). Both come from the
    /// tail of the transcript and are re-read whenever the file changes.
    package func titleAndLastPrompt(sessionId: String, projectsDir: URL) -> (title: String?, lastPrompt: String?) {
        guard let url = locateJSONL(sessionId: sessionId, projectsDir: projectsDir) else { return (nil, nil) }
        return titleAndLastPrompt(for: url, cacheKey: sessionId)
    }

    package func titleAndLastPrompt(for url: URL, cacheKey: String? = nil) -> (title: String?, lastPrompt: String?) {
        let key = cacheKey ?? url.path
        let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = attrs?.contentModificationDate ?? .distantPast
        let size = attrs?.fileSize ?? 0

        cacheLock.lock()
        if let c = tailCache[key], c.mtime == mtime, c.size == size {
            cacheLock.unlock(); return (c.title, c.lastPrompt)
        }
        cacheLock.unlock()

        let found = Self.scanTail(of: url, size: size, budget: tailBudget)
        cacheLock.lock()
        tailCache[key] = TailInfo(mtime: mtime, size: size, title: found.title, lastPrompt: found.lastPrompt)
        cacheLock.unlock()
        return found
    }

    /// Scans the last `budget` bytes for the newest `ai-title` and
    /// `last-prompt` records. Exposed for tests.
    package static func scanTail(of url: URL, size: Int, budget: Int) -> (title: String?, lastPrompt: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        let start = max(0, size - budget)
        if start > 0 { try? handle.seek(toOffset: UInt64(start)) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return (nil, nil) }
        return scanTail(data: data, skipFirstPartialLine: start > 0)
    }

    package static func scanTail(data: Data, skipFirstPartialLine: Bool) -> (title: String?, lastPrompt: String?) {
        let titleMarker = Data("\"type\":\"ai-title\"".utf8)
        let promptMarker = Data("\"type\":\"last-prompt\"".utf8)
        var title: String? = nil
        var lastPrompt: String? = nil
        var start = data.startIndex
        var first = skipFirstPartialLine
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<nl]
            start = nl + 1
            if first { first = false; continue }
            if line.isEmpty { continue }
            let isTitle = line.range(of: titleMarker) != nil
            let isPrompt = !isTitle && line.range(of: promptMarker) != nil
            guard isTitle || isPrompt,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if isTitle, let t = json["aiTitle"] as? String {
                let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { title = cleaned }
            } else if isPrompt, let p = json["lastPrompt"] as? String {
                let cleaned = p.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { lastPrompt = String(cleaned.prefix(300)) }
            }
        }
        return (title, lastPrompt)
    }

    /// Returns the first real user prompt for a session, or nil if none found.
    /// Skips scheduled-task preambles and command-name blocks.
    package func firstPrompt(sessionId: String, projectsDir: URL) -> String? {
        cacheLock.lock()
        if let cached = cache[sessionId] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        guard let jsonlURL = locateJSONL(sessionId: sessionId, projectsDir: projectsDir)
        else { return nil }

        let prompt = extractFirstPrompt(from: jsonlURL)
        if let prompt {
            cacheLock.lock()
            cache[sessionId] = prompt
            cacheLock.unlock()
        }
        return prompt
    }

    // MARK: - Private

    private func locateJSONL(sessionId: String, projectsDir: URL) -> URL? {
        // JSONL lives at ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl.
        // We don't reliably know the encoding, so scan project subdirs.
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return nil }
        let target = "\(sessionId).jsonl"
        for dir in projectDirs where dir.hasDirectoryPath {
            let candidate = dir.appendingPathComponent(target)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func extractFirstPrompt(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: readBudget), !data.isEmpty
        else { return nil }

        // Parse line-by-line until first qualifying user message.
        var start = 0
        while start < data.count {
            guard let nl = data[start...].firstIndex(of: 0x0A) else { break }
            let lineData = data[start..<nl]
            defer { start = nl + 1 }
            if lineData.isEmpty { continue }

            guard let json = try? JSONSerialization.jsonObject(with: lineData)
                    as? [String: Any],
                  json["type"] as? String == "user",
                  let message = json["message"] as? [String: Any]
            else { continue }

            guard let text = extractText(from: message["content"]) else { continue }
            if let cleaned = cleanPrompt(text) { return cleaned }
        }
        return nil
    }

    /// Message content can be a string or an array of content blocks.
    private func extractText(from content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            for block in arr {
                if block["type"] as? String == "text",
                   let s = block["text"] as? String { return s }
            }
        }
        return nil
    }

    /// Strip wrapper tags (scheduled-task, command-name, etc.), collapse
    /// whitespace, trim, and truncate to ~80 chars.
    private func cleanPrompt(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip auto-injected wrappers: <scheduled-task>, <command-name>, etc.
        // These are tool-generated, not real user prompts.
        if text.hasPrefix("<scheduled-task") || text.hasPrefix("<command-name")
           || text.hasPrefix("<command-message") || text.hasPrefix("<bash-stdout")
           || text.hasPrefix("<local-command") {
            return nil
        }

        // Collapse newlines/tabs/multi-space into single spaces for the preview.
        text = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        guard !text.isEmpty else { return nil }
        if text.count > 80 {
            let idx = text.index(text.startIndex, offsetBy: 80)
            text = String(text[..<idx]) + "…"
        }
        return text
    }
}
