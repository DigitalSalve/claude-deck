import Foundation

@Observable
package final class SessionManager {
    package var activeSessions: [ClaudeSession] = []
    package var recentSessions: [SessionHistory] = []
    package var stats = UsageStats()
    package var isLoading = true

    private static let refreshInterval: TimeInterval = 300   // token stats + Recent tab
    private static let activePollInterval: TimeInterval = 15 // pid-death detection
    private static let weeklyAnchorInterval: TimeInterval = 3600 // reset moves weekly

    private let claudeDir: URL
    private let sessionsDir: URL
    private let projectsDir: URL
    private var timer: Timer?
    private var activeTimer: Timer?
    private var sessionsWatcher: DispatchSourceFileSystemObject?
    // .workItem drains autoreleased Foundation objects after every scan;
    // the default lets them pile up across runs on a long-lived queue.
    private let queue = DispatchQueue(label: "io.github.digitalsalve.claudedeck.scan", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    /// Only touched on `queue`.
    private var weeklyAnchorsCache: (value: Date?, computedAt: Date)?
    private let watchQueue = DispatchQueue(label: "io.github.digitalsalve.claudedeck.sessions.watch", qos: .utility)

    package init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        claudeDir = home.appendingPathComponent(".claude")
        sessionsDir = claudeDir.appendingPathComponent("sessions")
        projectsDir = claudeDir.appendingPathComponent("projects")

        // Always compute stats on launch — UsageStats isn't persisted, only the
        // raw TokenCache is. Without this the UI shows 0/limit until the next
        // full refresh fires minutes later.
        refreshActiveOnlyAsync()
        refreshAsync()

        // Token stats + Recent refresh. Every file read is incremental (only
        // bytes appended since the last pass), so this stays cheap.
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAsync()
        }

        // Fast poll: detects pid death and catches any events the watcher missed.
        activeTimer = Timer.scheduledTimer(withTimeInterval: Self.activePollInterval, repeats: true) { [weak self] _ in
            self?.refreshActiveOnlyAsync()
        }

        // Instant reaction to new/removed session files.
        startSessionsWatcher()
    }

    deinit {
        timer?.invalidate()
        activeTimer?.invalidate()
        sessionsWatcher?.cancel()
    }

    private func startSessionsWatcher() {
        // Create dir if missing — opening a non-existent dir returns -1.
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: watchQueue
        )
        src.setEventHandler { [weak self] in
            self?.refreshActiveOnlyAsync()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        sessionsWatcher = src
    }

    package func refresh() {
        refreshAsync(forceWeeklyAnchors: true)
    }

    /// Fast refresh: active sessions only. Cheap enough to run every 15s and
    /// on every session-file event. Recent + token stats wait for refreshAsync.
    private func refreshActiveOnlyAsync() {
        queue.async { [weak self] in
            guard let self else { return }
            let active = self.scanActiveSessions()
            let windows = UsageWindows.load()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activeSessions = active
                if self.stats.usageWindows != windows {
                    var s = self.stats
                    s.usageWindows = windows
                    self.stats = s
                }
                self.isLoading = false
            }
        }
    }

    package func killSession(_ session: ClaudeSession) {
        guard let pid = session.pid else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/kill")
        proc.arguments = ["\(pid)"]
        try? proc.run()
        proc.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshAsync()
        }
    }

    // MARK: - Private

    private func refreshAsync(forceWeeklyAnchors: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            let active = self.scanActiveSessions()
            let recent = self.scanRecentSessions()
            let weeklyAnchor: Date?
            if !forceWeeklyAnchors, let cached = self.weeklyAnchorsCache,
               Date().timeIntervalSince(cached.computedAt) < Self.weeklyAnchorInterval {
                weeklyAnchor = cached.value
            } else {
                weeklyAnchor = self.scanWeeklyAnchor()
                self.weeklyAnchorsCache = (weeklyAnchor, Date())
            }
            QuotaAnalyzer.shared.maybePersistCache()

            let activeIds = Set(active.map { $0.id })
            let now = Date()

            // ── Token cache ───────────────────────────────────────────────────
            var cache = TokenCacheManager.shared.load()

            if cache.fileOffsets.isEmpty {
                cache = TokenCacheManager.shared.bootstrap(projectsDir: self.projectsDir)
            } else {
                cache = TokenCacheManager.shared.update(
                    cache: cache,
                    activeSessionIds: activeIds,
                    projectsDir: self.projectsDir
                )
                cache.prune(before: now.addingTimeInterval(-7 * 3600))
            }

            cache.lastFullRefresh = Date()
            TokenCacheManager.shared.save(cache)

            // ── 5h rolling window ─────────────────────────────────────────────
            let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
            let windowOutputTokens = cache.windowTotal(since: fiveHoursAgo)
            let windowStart: Date = cache.entries
                .filter { $0.messageTimestamp >= fiveHoursAgo }
                .map { $0.messageTimestamp }
                .min() ?? fiveHoursAgo

            let computed = self.computeStats(
                active: active,
                recent: recent,
                windowStart: windowStart,
                windowOutputTokens: windowOutputTokens,
                weeklyAnchor: weeklyAnchor
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activeSessions = active
                self.recentSessions = recent
                self.stats = computed
                self.isLoading = false
            }
        }
    }

    private func scanActiveSessions() -> [ClaudeSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ClaudeSession? in
                guard let data = try? Data(contentsOf: url),
                      var session = try? JSONDecoder().decode(ClaudeSession.self, from: data) else {
                    return nil
                }
                guard session.isActive else { return nil }
                // Resolve isDesktop HERE (off the main thread) — spawning
                // /bin/ps from a SwiftUI getter crashes the render path.
                session.resolveIsDesktop()
                // Load first prompt from the session's JSONL for the row preview.
                session.firstPrompt = SessionPromptReader.shared.firstPrompt(
                    sessionId: session.id, projectsDir: projectsDir
                )
                let tail = SessionPromptReader.shared.titleAndLastPrompt(
                    sessionId: session.id, projectsDir: projectsDir
                )
                session.title = tail.title
                session.lastPrompt = tail.lastPrompt
                return session
            }
            .sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }

    private func scanRecentSessions() -> [SessionHistory] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var sessions: [SessionHistory] = []

        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }

            // Sort by modification date, take only most recent files
            let jsonlFiles = files
                .filter { $0.pathExtension == "jsonl" }
                .sorted { a, b in
                    let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return aDate > bDate
                }
                .prefix(5) // Only scan 5 most recent per project

            for file in jsonlFiles {
                if let history = QuotaAnalyzer.shared.sessionHistory(for: file, projectPath: dir.lastPathComponent) {
                    sessions.append(history)
                }
            }
        }

        return sessions
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(30)
            .map { history in
                var h = history
                let url = projectsDir
                    .appendingPathComponent(h.projectPath)
                    .appendingPathComponent("\(h.id).jsonl")
                h.firstPrompt = firstPrompt(in: url)
                let tail = SessionPromptReader.shared.titleAndLastPrompt(for: url, cacheKey: h.id)
                h.title = tail.title
                h.lastPrompt = tail.lastPrompt
                return h
            }
    }

    /// Text of the first user message (raw, 200 chars) from the head of the
    /// file only — the opening message is almost always in the first lines.
    private func firstPrompt(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let content = String(data: data, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "user",
                  let message = json["message"] as? [String: Any] else { continue }

            // Content can be a plain string or an array of content blocks
            if let text = message["content"] as? String, !text.isEmpty {
                return String(text.prefix(200))
            }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                        return String(text.prefix(200))
                    }
                }
            }
        }
        return nil
    }

    /// Finds the oldest output-bearing message in the 7-day window per model
    /// category, for the weekly reset time. Reads only bytes appended since
    /// the last pass (QuotaAnalyzer's per-file cache).
    private func scanWeeklyAnchor() -> Date? {
        let fm = FileManager.default
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)

        var oldest: Date? = nil

        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return nil
        }

        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard modDate >= sevenDaysAgo,
                      let hit = QuotaAnalyzer.shared.firstOutputTimestamp(for: file, since: sevenDaysAgo)
                else { continue }

                if oldest == nil || hit.timestamp < oldest! { oldest = hit.timestamp }
            }
        }

        return oldest
    }

    private func computeStats(active: [ClaudeSession], recent: [SessionHistory],
                              windowStart: Date, windowOutputTokens: Int,
                              weeklyAnchor: Date?) -> UsageStats {
        var s = UsageStats()
        s.activeSessions = active.count
        s.totalSessions  = recent.count

        let now = Date()

        var ptCal = Calendar(identifier: .gregorian)
        ptCal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // ── 5h window — use pre-scanned output tokens ────────────────────────
        s.fiveHourTokens = windowOutputTokens

        // Window display — always use the resolved anchor so reset timer is correct
        s.windowStart    = windowStart
        s.windowIsActive = !active.isEmpty

        // ── Time windows ─────────────────────────────────────────────────────
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)

        // ── Peak hours: Mon–Fri, 5–11 AM PT ──────────────────────────────────
        let ptHour    = ptCal.component(.hour,    from: now)
        let ptWeekday = ptCal.component(.weekday, from: now)
        s.isPeakHours = (ptWeekday >= 2 && ptWeekday <= 6) && (ptHour >= 5 && ptHour < 11)

        // ── Accumulate per-session (recent history) ───────────────────────────
        for sess in recent {
            let outputTokens = sess.totalOutputTokens
            let cost = sess.estimatedCost

            if sess.lastActivity >= sevenDaysAgo {
                s.sevenDayAllTokens += outputTokens
            }

            s.allTimeTokens += outputTokens
            s.allTimeCost   += cost

            let m = sess.model ?? "unknown"
            s.sessionsByModel[m, default: 0] += 1
        }

        // Reset = 7 days after the oldest message timestamp found in the full 7-day scan
        s.weeklyAllResetDate = weeklyAnchor.map { $0.addingTimeInterval(7 * 24 * 3600) }

        // ── Live windows from Claude Code (preferred over every estimate above)
        s.usageWindows = UsageWindows.load(now: now)

        return s
    }
}
