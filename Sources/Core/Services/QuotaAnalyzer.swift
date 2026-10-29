import Foundation

package final class QuotaAnalyzer {
    package static let shared = QuotaAnalyzer()

    private let claudeDir: URL
    private let projectsDir: URL
    private let sessionsDir: URL
    private let formatter: ISO8601DateFormatter

    // Byte-level prefilter markers. Most JSONL lines are user messages or tool
    // results; parsing them with JSONSerialization costs ~50-100x more than a
    // plain byte scan. We only fully parse lines that look like they carry
    // assistant usage data or an entrypoint.
    private static let assistantMarker: [UInt8] = Array("\"type\":\"assistant\"".utf8)
    private static let entrypointMarker: [UInt8] = Array("\"entrypoint\"".utf8)
    /// Claude Code writes one `model` attachment record per session with the
    /// model's marketing name. Cheap byte marker so we only JSON-parse that line.
    private static let modelIdentityMarker: [UInt8] = Array("\"marketingName\"".utf8)
    private static let userMarker: [UInt8] = Array("\"type\":\"user\"".utf8)

    // Per-file cache. Key = file path. Reused across refreshes so unchanged
    // files cost only one stat() call. Active sessions resume parsing from
    // the last byte offset instead of re-reading the whole file.
    private let cacheLock = NSLock()
    private var fileCache: [String: FileCacheEntry] = [:]

    /// Debounce persist-to-disk so rapid analyze() calls during active
    /// sessions don't rewrite the cache file every 500ms.
    private let persistLock = NSLock()
    private var lastPersistTime: Date = .distantPast
    private let persistMinInterval: TimeInterval = 10

    /// Cap per-file carry buffer. Lines are typically <100 KB. If a file
    /// has no newline for >1 MB, treat it as corrupt and drop the buffer.
    private let maxCarrySize = 1_048_576

    private convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(claudeDir: home.appendingPathComponent(".claude"))
    }

    /// Testable init with explicit `.claude` directory root.
    package init(claudeDir: URL) {
        self.claudeDir = claudeDir
        self.projectsDir = claudeDir.appendingPathComponent("projects")
        self.sessionsDir = claudeDir.appendingPathComponent("sessions")

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        loadCacheFromDisk()
    }

    private var cacheURL: URL {
        claudeDir.appendingPathComponent("claude-deck-cache.json")
    }

    /// Persist the in-memory file cache to disk. Called after each analyze()
    /// so the next app launch doesn't pay the full cold-start scan cost.
    package func persistCache() {
        let snapshot: [String: FileCacheEntry] = {
            cacheLock.lock(); defer { cacheLock.unlock() }
            return fileCache
        }()
        guard let data = try? JSONEncoder().encode(CacheEnvelope(version: Self.cacheVersion, entries: snapshot))
        else { return }
        // Data.write(.atomic) is already tmp-write-then-rename under the hood.
        // Avoid FileManager.replaceItemAt — it can hang on files with extended
        // attributes (observed on macOS).
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              envelope.version == Self.cacheVersion
        else { return }
        cacheLock.lock()
        fileCache = envelope.entries
        cacheLock.unlock()
    }

    /// Bump when FileCacheEntry gains fields — old caches are discarded and
    /// rebuilt once (streamed, so the rebuild is CPU-only, not memory).
    private static let cacheVersion = 4

    private struct CacheEnvelope: Codable {
        let version: Int
        let entries: [String: FileCacheEntry]
    }

    package enum Period: String, CaseIterable {
        case sixHours   = "6h"
        case twelveHours = "12h"
        case oneDay     = "1d"
        case threeDays  = "3d"
        case sevenDays  = "7d"
        case thirtyDays = "30d"
        case allTime    = "All"
        /// User-defined window. Its actual cutoff lives on QuotaLiveStore
        /// as `customHours` so UI state stays in one place; Period itself
        /// stays a pure enum that can be compared and serialized cleanly.
        case custom     = "Custom"

        package var label: String {
            switch self {
            case .sixHours:    return "last 6 hours"
            case .twelveHours: return "last 12 hours"
            case .oneDay:      return "last 24 hours"
            case .threeDays:   return "last 3 days"
            case .sevenDays:   return "last 7 days"
            case .thirtyDays:  return "last 30 days"
            case .allTime:     return "all time"
            case .custom:      return "custom range"
            }
        }

        /// Standard periods return a fixed cutoff. `.custom` is resolved by
        /// the caller (QuotaAnalyzer.analyze) using the store's customHours.
        var cutoff: Date {
            let now = Date()
            switch self {
            case .sixHours:    return now.addingTimeInterval(-6 * 3600)
            case .twelveHours: return now.addingTimeInterval(-12 * 3600)
            case .oneDay:      return now.addingTimeInterval(-24 * 3600)
            case .threeDays:   return now.addingTimeInterval(-3 * 24 * 3600)
            case .sevenDays:   return now.addingTimeInterval(-7 * 24 * 3600)
            case .thirtyDays:  return now.addingTimeInterval(-30 * 24 * 3600)
            case .allTime:     return .distantPast
            case .custom:      return .distantPast  // overridden by analyze()
            }
        }
    }

    /// Analyze all sessions within the given period. Call on a background
    /// queue. Pass `customHours` when `period == .custom`; otherwise ignored.
    package func analyze(
        period: Period = .sevenDays,
        customHours: Double = 4,
        customRange: DateInterval? = nil
    ) -> QuotaReport {
        let fm = FileManager.default
        let cutoff: Date = {
            if period == .custom {
                if let r = customRange { return r.start }
                let h = max(0.1, customHours)
                return Date().addingTimeInterval(-h * 3600)
            }
            return period.cutoff
        }()
        // Upper bound: only for an explicit date range. Sessions that began
        // after it are excluded; everything else is open-ended to now.
        let until: Date? = (period == .custom) ? customRange?.end : nil
        let activeIds = scanActiveSessionIds()

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else {
            return .empty
        }

        var reports: [QuotaSessionReport] = []
        var visitedPaths = Set<String>()

        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }

            let projectPath = dir.lastPathComponent
            let projectName = decodeProjectName(projectPath)

            for file in files where file.pathExtension == "jsonl" {
                processSessionFile(
                    file: file,
                    projectName: projectName,
                    parentSessionId: nil,
                    isSubagent: false,
                    activeIds: activeIds,
                    cutoff: cutoff, until: until,
                    visitedPaths: &visitedPaths,
                    reports: &reports
                )

                // Each parent session may have a sibling `{sessionId}/subagents/`
                // directory containing its sidechain runs. Walk it so those
                // tokens show up in the report instead of being invisible.
                let parentId = file.deletingPathExtension().lastPathComponent
                let subagentDir = dir.appendingPathComponent(parentId)
                    .appendingPathComponent("subagents")
                processSubagentDir(
                    subagentDir,
                    projectName: projectName,
                    parentSessionId: parentId,
                    activeIds: activeIds,
                    cutoff: cutoff, until: until,
                    visitedPaths: &visitedPaths,
                    reports: &reports
                )
            }
        }

        // Evict cache entries for files that no longer exist.
        pruneCache(keeping: visitedPaths)
        // Evict stubs + LRU-trim so long-running sessions don't let the cache
        // grow forever. Called on every analyze — cheap, no I/O.
        evictStaleCache()
        maybePersistCache()
        // Durable token history, independent of transcript retention.
        UsageLedger.shared.record(ledgerSamples())

        let label: String = {
            guard period == .custom, let r = customRange else { return period.label }
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return "\(f.string(from: r.start)) – \(f.string(from: r.end))"
        }()
        return QuotaReport(sessions: reports, periodLabel: label)
    }

    /// Shared per-file handler for top-level sessions and subagent sidechains.
    /// Stat-cached fast path → stub for out-of-cutoff → incremental parse.
    private func processSessionFile(
        file: URL,
        projectName: String,
        parentSessionId: String?,
        isSubagent: Bool,
        activeIds: Set<String>,
        cutoff: Date,
        until: Date? = nil,
        visitedPaths: inout Set<String>,
        reports: inout [QuotaSessionReport]
    ) {
        autoreleasepool {
            let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey
            ])
            let modDate = values?.contentModificationDate ?? .distantPast
            let fileSize = values?.fileSize ?? 0
            guard fileSize > 0 else { return }

            let path = file.path
            visitedPaths.insert(path)

            // Fast path: stat unchanged AND entry isn't a stub → reuse cached
            // aggregates. Stubs are stored for files outside cutoff to
            // short-circuit next scan; a broader period still needs to parse.
            if let cached = readCache(path),
               cached.size == fileSize,
               cached.mtime == modDate,
               !(cached.parsedOffset == 0 && cached.turns == 0) {
                if let report = buildReport(
                    entry: cached,
                    file: file,
                    projectName: projectName,
                    activeIds: activeIds,
                    cutoff: cutoff, until: until
                ) {
                    reports.append(report)
                }
                return
            }

            // Skip wholly outside cutoff and not in cache (never displayed).
            // Still cache a stub so next refresh can short-circuit.
            guard modDate >= cutoff else {
                var stub = FileCacheEntry(mtime: modDate, size: fileSize)
                stub.parentSessionId = parentSessionId
                stub.isSubagent = isSubagent
                writeCache(path, stub)
                return
            }

            var entry = parseFile(
                file: file,
                mtime: modDate,
                size: fileSize,
                previous: readCache(path)
            )
            // Tag before writing so the entry's provenance survives restarts
            // even if parseFile didn't see any usage lines yet.
            entry.parentSessionId = parentSessionId
            entry.isSubagent = isSubagent
            writeCache(path, entry)

            if let report = buildReport(
                entry: entry,
                file: file,
                projectName: projectName,
                activeIds: activeIds,
                cutoff: cutoff, until: until
            ) {
                reports.append(report)
            }
        }
    }

    /// Snapshot of every fully parsed transcript's cumulative totals, for the
    /// usage ledger. Stubs (never parsed, turns == 0) are skipped.
    package func ledgerSamples() -> [LedgerSample] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return fileCache.compactMap { path, e in
            guard e.turns > 0 else { return nil }
            let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return LedgerSample(
                path: path, sessionId: sessionId, model: e.model, isSubagent: e.isSubagent,
                input: e.totalInput, cacheRead: e.totalCacheRead, cacheWrite: e.totalCacheWrite,
                output: e.totalOutput, thinking: e.totalThinking, turns: e.turns,
                lastActivity: Self.saneActivityDate(e.lastTimestamp, fallback: e.mtime))
        }
    }

    /// Transcripts occasionally carry impossible timestamps (fixtures, clock
    /// resets). Anything before Claude Code existed is replaced by the file's
    /// mtime so the ledger never books a day in 2019.
    package static let earliestPlausible = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
    package static func saneActivityDate(_ ts: Date?, fallback: Date) -> Date {
        guard let ts, ts >= earliestPlausible else { return fallback }
        return ts
    }

    /// Feed a transcript `model` attachment record to the catalog so a model
    /// released after this build still shows its real name. Shape:
    /// `{"attachment":{"type":"model","identity":{"modelId":…,"marketingName":…}}}`
    package static func learnModelIdentity(from lineData: Data,
                                           into catalog: ModelCatalog = .shared) {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let attachment = json["attachment"] as? [String: Any],
              attachment["type"] as? String == "model",
              let identity = attachment["identity"] as? [String: Any],
              let id = identity["modelId"] as? String,
              let name = identity["marketingName"] as? String
        else { return }
        catalog.learn(id: id, marketingName: name)
    }

    /// Walk `{project}/{parentId}/subagents/*.jsonl` and fold each file's
    /// tokens into the report tagged with the parent id. Silently no-ops if
    /// the directory doesn't exist (most sessions have no subagents).
    private func processSubagentDir(
        _ dir: URL,
        projectName: String,
        parentSessionId: String,
        activeIds: Set<String>,
        cutoff: Date,
        until: Date? = nil,
        visitedPaths: inout Set<String>,
        reports: inout [QuotaSessionReport]
    ) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        for file in files where file.pathExtension == "jsonl" {
            processSessionFile(
                file: file,
                projectName: projectName,
                parentSessionId: parentSessionId,
                isSubagent: true,
                activeIds: activeIds,
                cutoff: cutoff, until: until,
                visitedPaths: &visitedPaths,
                reports: &reports
            )
        }
    }

    /// Persist only if the last write was long enough ago. Called from
    /// hot paths that fire rapidly during active sessions.
    package func maybePersistCache() {
        persistLock.lock()
        let now = Date()
        let shouldPersist = now.timeIntervalSince(lastPersistTime) >= persistMinInterval
        if shouldPersist { lastPersistTime = now }
        persistLock.unlock()
        if shouldPersist { persistCache() }
    }

    // MARK: - Cache plumbing

    private struct FileCacheEntry: Codable {
        var mtime: Date
        var size: Int
        var parsedOffset: Int = 0
        var turns: Int = 0
        var firstInputTokens: Int? = nil
        var lastInputTokens: Int = 0
        var totalInput: Int = 0
        var totalOutput: Int = 0
        var totalCacheRead: Int = 0
        var totalCacheWrite: Int = 0
        /// Output tokens spent on thinking (`usage.output_tokens_details.thinking_tokens`).
        var totalThinking: Int = 0
        /// Server-side tool calls (`usage.server_tool_use`).
        var webSearches: Int = 0
        var webFetches: Int = 0
        var model: String? = nil
        var lastTimestamp: Date? = nil
        var firstTimestamp: Date? = nil
        /// User + assistant lines, matching the Recent tab's "N msgs".
        var messageCount: Int = 0
        /// First output-bearing assistant timestamp per hour (key = epoch
        /// hours), last 8 days only. Lets the weekly-reset anchor be found
        /// without re-reading the file.
        var hourFirstOutput: [Int: Date] = [:]
        var entrypoint: String? = nil
        /// Parent session id if this entry is a subagent sidechain transcript.
        var parentSessionId: String? = nil
        var isSubagent: Bool = false
        /// Bytes after the last newline in the file — not yet a complete line.
        /// Excluded from Codable: persisting it base64-encoded bloated the
        /// cache file unbounded. Safe to drop because `parsedOffset` points
        /// at the first byte of the next (possibly partial) line, so the
        /// next parse reconstructs carry from the file itself.
        var carry: Data = Data()

        private enum CodingKeys: String, CodingKey {
            case mtime, size, parsedOffset, turns
            case firstInputTokens, lastInputTokens
            case totalInput, totalOutput, totalCacheRead, totalCacheWrite
            case totalThinking, webSearches, webFetches
            case model, lastTimestamp, firstTimestamp, messageCount, hourFirstOutput, entrypoint
            case parentSessionId, isSubagent
        }
    }

    private func readCache(_ path: String) -> FileCacheEntry? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return fileCache[path]
    }

    private func writeCache(_ path: String, _ entry: FileCacheEntry) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        fileCache[path] = entry
    }

    private func pruneCache(keeping: Set<String>) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        for key in fileCache.keys where !keeping.contains(key) {
            fileCache.removeValue(forKey: key)
        }
    }

    /// Hard cap on cached file entries. A machine running the app for years
    /// accumulates entries for every session ever seen; without a ceiling
    /// the in-memory dict and the persisted JSON both grow without bound.
    /// 3000 covers ~a year of heavy daily use with headroom.
    private let maxCacheEntries = 3000

    /// Evict cache entries that can't contribute to any report we'd render:
    /// - stubs (never parsed; only held to short-circuit cutoff) with
    ///   mtime older than the widest period we support
    /// - if still over the hard cap, drop the oldest by mtime (LRU)
    ///
    /// Runs after each analyze(). Cheap — no file I/O, just dict ops.
    private func evictStaleCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }

        // Stubs beyond widest period cutoff will never be shown again.
        let widestCutoff = Period.thirtyDays.cutoff
        for (path, entry) in fileCache {
            let isStub = entry.parsedOffset == 0 && entry.turns == 0
            if isStub && entry.mtime < widestCutoff {
                fileCache.removeValue(forKey: path)
            }
        }

        // Hard cap: drop oldest-mtime entries until we're under the limit.
        if fileCache.count > maxCacheEntries {
            let sorted = fileCache.sorted { $0.value.mtime < $1.value.mtime }
            let excess = fileCache.count - maxCacheEntries
            for i in 0..<excess {
                fileCache.removeValue(forKey: sorted[i].key)
            }
        }
    }

    // MARK: - Incremental parsing

    private func parseFile(
        file: URL,
        mtime: Date,
        size: Int,
        previous: FileCacheEntry?
    ) -> FileCacheEntry {
        // Decide whether to resume from previous offset or start over.
        // Restart if the file was truncated or went backwards in time.
        var entry: FileCacheEntry
        if let prev = previous,
           size >= prev.size,
           mtime >= prev.mtime,
           prev.parsedOffset <= size {
            entry = prev
            entry.mtime = mtime
            entry.size = size
        } else {
            entry = FileCacheEntry(mtime: mtime, size: size)
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return entry }
        defer { try? handle.close() }

        if entry.parsedOffset > 0 {
            do { try handle.seek(toOffset: UInt64(entry.parsedOffset)) }
            catch { entry = FileCacheEntry(mtime: mtime, size: size) }
        }

        let chunkSize = 256 * 1024
        let newline: UInt8 = 0x0A
        var bytesConsumed = entry.parsedOffset
        var skippingLongLine = false

        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            entry.carry.append(chunk)

            while let nlIndex = entry.carry.firstIndex(of: newline) {
                let lineLen = nlIndex - entry.carry.startIndex
                let lineData = entry.carry.subdata(in: entry.carry.startIndex..<nlIndex)
                entry.carry.removeSubrange(entry.carry.startIndex...nlIndex)
                bytesConsumed += lineLen + 1

                // Tail of an oversized line already dropped below.
                if skippingLongLine { skippingLongLine = false; continue }
                guard !lineData.isEmpty else { continue }

                // Byte-level prefilter: skip lines that can't contribute.
                let hasAssistant = lineData.contains(Self.assistantMarker)
                if !hasAssistant && lineData.contains(Self.userMarker) {
                    entry.messageCount += 1
                }
                if lineData.contains(Self.modelIdentityMarker) {
                    Self.learnModelIdentity(from: lineData)
                }
                let needsEntrypoint = entry.entrypoint == nil
                    && lineData.contains(Self.entrypointMarker)
                guard hasAssistant || needsEntrypoint else { continue }

                autoreleasepool {
                    guard let json = try? JSONSerialization.jsonObject(with: lineData)
                            as? [String: Any]
                    else { return }

                    if needsEntrypoint, let ep = json["entrypoint"] as? String {
                        entry.entrypoint = ep
                    }

                    guard hasAssistant, json["type"] as? String == "assistant" else { return }
                    entry.messageCount += 1

                    guard let message = json["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any]
                    else { return }

                    let inTok = (usage["input_tokens"] as? Int ?? 0)
                    let cacheRead = (usage["cache_read_input_tokens"] as? Int ?? 0)
                    let cacheWrite = (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    let inputTokens = inTok + cacheRead + cacheWrite
                    let outputTokens = usage["output_tokens"] as? Int ?? 0

                    guard inputTokens > 0 || outputTokens > 0 else { return }

                    entry.turns += 1
                    if entry.firstInputTokens == nil { entry.firstInputTokens = inputTokens }
                    entry.lastInputTokens = inputTokens
                    entry.totalInput += inTok
                    entry.totalCacheRead += cacheRead
                    entry.totalCacheWrite += cacheWrite
                    entry.totalOutput += outputTokens
                    if let details = usage["output_tokens_details"] as? [String: Any],
                       let thinking = details["thinking_tokens"] as? Int {
                        entry.totalThinking += thinking
                    }
                    if let server = usage["server_tool_use"] as? [String: Any] {
                        entry.webSearches += server["web_search_requests"] as? Int ?? 0
                        entry.webFetches  += server["web_fetch_requests"] as? Int ?? 0
                    }

                    if let m = message["model"] as? String { entry.model = m }
                    if let ts = json["timestamp"] as? String,
                       let parsed = formatter.date(from: ts) {
                        if entry.firstTimestamp == nil { entry.firstTimestamp = parsed }
                        entry.lastTimestamp = parsed
                        if outputTokens > 0 {
                            let hour = Int(parsed.timeIntervalSince1970 / 3600)
                            if entry.hourFirstOutput[hour] == nil {
                                entry.hourFirstOutput[hour] = parsed
                            }
                        }
                    }
                }
            }

            // Only a partial line remains. Lines over the cap are pasted
            // screenshots / attachments (never usage-bearing), so drop the
            // buffer rather than grow it, and skip to the next newline.
            // Checked after line extraction so complete lines in the same
            // chunk are never discarded with it.
            if entry.carry.count > maxCarrySize {
                if !skippingLongLine && entry.carry.contains(Self.userMarker) {
                    entry.messageCount += 1
                }
                skippingLongLine = true
                bytesConsumed += entry.carry.count
                entry.carry = Data()
            }
        }

        entry.parsedOffset = bytesConsumed
        let oldestHour = Int(Date().timeIntervalSince1970 / 3600) - 8 * 24
        entry.hourFirstOutput = entry.hourFirstOutput.filter { $0.key >= oldestHour }
        return entry
    }

    // MARK: - Single-file incremental access (SessionManager)

    /// Returns the cached entry for one file, parsing only bytes appended
    /// since the last call. Unchanged files cost one stat().
    private func refreshedEntry(for file: URL) -> FileCacheEntry? {
        // URL caches resource values per instance; a reused URL would report
        // a stale size and silently skip appended bytes.
        var file = file
        file.removeAllCachedResourceValues()
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modDate = values?.contentModificationDate ?? .distantPast
        let fileSize = values?.fileSize ?? 0
        guard fileSize > 0 else { return nil }

        let path = file.path
        let cached = readCache(path)
        if let cached, cached.size == fileSize, cached.mtime == modDate,
           !(cached.parsedOffset == 0 && cached.turns == 0) {
            return cached
        }
        var entry = parseFile(file: file, mtime: modDate, size: fileSize, previous: cached)
        entry.parentSessionId = cached?.parentSessionId
        entry.isSubagent = cached?.isSubagent ?? false
        writeCache(path, entry)
        return entry
    }

    /// Recent-tab summary for one top-level session file. `firstPrompt` is
    /// left nil — SessionPromptReader owns that.
    package func sessionHistory(for file: URL, projectPath: String) -> SessionHistory? {
        autoreleasepool {
            guard let e = refreshedEntry(for: file) else { return nil }
            return SessionHistory(
                id: file.deletingPathExtension().lastPathComponent,
                projectPath: projectPath,
                lastActivity: e.lastTimestamp ?? e.mtime,
                messageCount: e.messageCount,
                totalInputTokens: e.totalInput,
                totalCacheReadTokens: e.totalCacheRead,
                totalCacheWriteTokens: e.totalCacheWrite,
                totalOutputTokens: e.totalOutput,
                model: e.model,
                name: nil,
                entrypoint: e.entrypoint,
                firstPrompt: nil,
                firstActivity: e.firstTimestamp
            )
        }
    }

    /// Earliest output-bearing assistant timestamp at or after `cutoff`, and
    /// the file's model. Hour-bucket precision: if the cutoff falls mid-hour,
    /// that hour is skipped, so the anchor can land up to 1h late.
    package func firstOutputTimestamp(for file: URL, since cutoff: Date) -> (timestamp: Date, model: String?)? {
        autoreleasepool {
            guard let e = refreshedEntry(for: file),
                  let ts = e.hourFirstOutput.values.filter({ $0 >= cutoff }).min()
            else { return nil }
            return (ts, e.model)
        }
    }

    // MARK: - Report assembly

    private func buildReport(
        entry: FileCacheEntry,
        file: URL,
        projectName: String,
        activeIds: Set<String>,
        cutoff: Date,
    until: Date? = nil
    ) -> QuotaSessionReport? {
        guard entry.turns > 0, let base = entry.firstInputTokens else { return nil }
        if let last = entry.lastTimestamp, last < cutoff { return nil }
        if let until, let first = entry.firstTimestamp, first > until { return nil }
        // If we never saw a timestamp but file mtime is before cutoff, skip.
        if entry.lastTimestamp == nil && entry.mtime < cutoff { return nil }

        let sessionId = file.deletingPathExtension().lastPathComponent
        let allTokens = entry.totalInput + entry.totalCacheRead
            + entry.totalCacheWrite + entry.totalOutput

        return QuotaSessionReport(
            id: sessionId,
            projectName: projectName,
            model: entry.model,
            turns: entry.turns,
            baseInputPerTurn: base,
            currentInputPerTurn: entry.lastInputTokens,
            totalTokens: allTokens,
            totalOutputTokens: entry.totalOutput,
            // Subagents run inside the parent process — never "active" on
            // their own. Only check activeIds for top-level sessions.
            isActive: entry.isSubagent ? false : activeIds.contains(sessionId),
            lastActivity: entry.lastTimestamp ?? .distantPast,
            entrypoint: entry.entrypoint,
            parentSessionId: entry.parentSessionId,
            isSubagent: entry.isSubagent,
            totalInputTokens: entry.totalInput + entry.totalCacheRead + entry.totalCacheWrite,
            thinkingTokens: entry.totalThinking,
            webSearchRequests: entry.webSearches,
            webFetchRequests: entry.webFetches
        )
    }

    // MARK: - Active session scan

    private func scanActiveSessionIds() -> Set<String> {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var ids = Set<String>()
        for file in files where file.pathExtension == "json" {
            autoreleasepool {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      let sid = json["sessionId"] as? String,
                      let pid = json["pid"] as? Int,
                      kill(pid_t(pid), 0) == 0
                else { return }
                ids.insert(sid)
            }
        }
        return ids
    }

    private func decodeProjectName(_ path: String) -> String {
        let decoded = path
            .replacingOccurrences(of: "-Users-", with: "/Users/")
            .replacingOccurrences(of: "-", with: "/")
        return URL(fileURLWithPath: decoded).lastPathComponent
    }
}

// MARK: - Data helpers

private extension Data {
    /// Byte-level substring search. Avoids allocating a String for the
    /// prefilter hot path.
    func contains(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        let n = needle.count
        let end = count - n
        return withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else { return false }
            let first = needle[0]
            var i = 0
            while i <= end {
                if base[i] == first {
                    var match = true
                    for j in 1..<n where base[i + j] != needle[j] {
                        match = false
                        break
                    }
                    if match { return true }
                }
                i += 1
            }
            return false
        }
    }
}
