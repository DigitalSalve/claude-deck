import Foundation

package struct TokenEntry: Codable {
    package let messageTimestamp: Date
    package let tokens: Int
    package let sessionId: String

    package init(messageTimestamp: Date, tokens: Int, sessionId: String) {
        self.messageTimestamp = messageTimestamp
        self.tokens = tokens
        self.sessionId = sessionId
    }
}

package struct TokenCache: Codable {
    package var fileOffsets: [String: Int] = [:]
    package var entries: [TokenEntry] = []
    package var windowAnchor: Date? = nil
    package var lastFullRefresh: Date? = nil

    package init() {}

    package mutating func prune(before cutoff: Date) {
        entries.removeAll { $0.messageTimestamp < cutoff }
    }

    package mutating func expireAnchorIfNeeded() {
        guard let anchor = windowAnchor else { return }
        if Date().timeIntervalSince(anchor) >= 5 * 3600 {
            windowAnchor = nil
        }
    }

    package func windowTotal(since start: Date) -> Int {
        entries.filter { $0.messageTimestamp >= start }.reduce(0) { $0 + $1.tokens }
    }

    package func earliestTimestamp(for sessionIds: Set<String>) -> Date? {
        entries
            .filter { sessionIds.contains($0.sessionId) }
            .map { $0.messageTimestamp }
            .min()
    }
}

// MARK: - Cache Manager

package final class TokenCacheManager {
    package static let shared = TokenCacheManager()

    private let cacheURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        cacheURL = claudeDir.appendingPathComponent("claudedeck-token-cache.json")

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    package func load() -> TokenCache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(TokenCache.self, from: data) else {
            return TokenCache()
        }
        return cache
    }

    package func save(_ cache: TokenCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Full scan of all JSONL files modified within the last 7 hours.
    /// Does NOT require active session IDs — captures tokens from any recently-used session,
    /// including ones that have already been closed.
    package func bootstrap(projectsDir: URL) -> TokenCache {
        var cache = TokenCache()
        let fm = FileManager.default
        let sevenHoursAgo = Date().addingTimeInterval(-7 * 3600)

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return cache }

        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                autoreleasepool {
                    // Skip files untouched in the last 7 hours.
                    let modDate = (try? file.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ))?.contentModificationDate ?? .distantPast
                    guard modDate >= sevenHoursAgo else { return }

                    let sid = file.deletingPathExtension().lastPathComponent
                    let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    guard fileSize > 0,
                          let content = try? String(contentsOf: file, encoding: .utf8) else { return }

                    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                        autoreleasepool {
                            guard let data = String(line).data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  json["type"] as? String == "assistant",
                                  let message = json["message"] as? [String: Any],
                                  let usage = message["usage"] as? [String: Any],
                                  let outputTokens = usage["output_tokens"] as? Int,
                                  outputTokens > 0
                            else { return }

                            let ts: Date
                            if let tsStr = json["timestamp"] as? String,
                               let parsed = formatter.date(from: tsStr) {
                                ts = parsed
                            } else {
                                ts = Date()
                            }

                            guard ts >= sevenHoursAgo else { return }

                            cache.entries.append(TokenEntry(
                                messageTimestamp: ts,
                                tokens: outputTokens,
                                sessionId: sid
                            ))
                        }
                    }

                    cache.fileOffsets[sid] = fileSize
                }
            }
        }

        return cache
    }

    package func update(cache: TokenCache, activeSessionIds: Set<String>, projectsDir: URL) -> TokenCache {
        guard !activeSessionIds.isEmpty else { return cache }

        var updated = cache
        let fm = FileManager.default
        let now = Date()

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return cache }

        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let sid = file.deletingPathExtension().lastPathComponent
                guard activeSessionIds.contains(sid) else { continue }
                autoreleasepool {
                    let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    var lastOffset = updated.fileOffsets[sid] ?? 0

                    if fileSize < lastOffset { lastOffset = 0 }
                    guard fileSize > lastOffset else { return }

                    guard let fh = try? FileHandle(forReadingFrom: file) else { return }
                    defer { try? fh.close() }
                    fh.seek(toFileOffset: UInt64(lastOffset))
                    let newData = fh.availableData
                    guard let newText = String(data: newData, encoding: .utf8) else { return }

                    for line in newText.split(separator: "\n", omittingEmptySubsequences: true) {
                        autoreleasepool {
                            guard let lineData = String(line).data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                            else { return }

                            guard json["type"] as? String == "assistant",
                                  let message = json["message"] as? [String: Any],
                                  let usage = message["usage"] as? [String: Any],
                                  let outputTokens = usage["output_tokens"] as? Int,
                                  outputTokens > 0
                            else { return }

                            let ts: Date
                            if let tsStr = json["timestamp"] as? String,
                               let parsed = formatter.date(from: tsStr) {
                                ts = parsed
                            } else {
                                ts = now
                            }

                            updated.entries.append(TokenEntry(
                                messageTimestamp: ts,
                                tokens: outputTokens,
                                sessionId: sid
                            ))
                        }
                    }

                    updated.fileOffsets[sid] = fileSize
                }
            }
        }

        updated.prune(before: now.addingTimeInterval(-7 * 3600))
        return updated
    }
}
