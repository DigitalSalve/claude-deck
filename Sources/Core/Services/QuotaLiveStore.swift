import Foundation
import Observation

/// Event-driven quota store. Watches `~/.claude/projects/` and each project
/// subdirectory via kernel-level file notifications (DispatchSource). When
/// anything changes, a debounced incremental analyze() runs and the report is
/// republished. Zero CPU when nothing is happening.
@Observable
package final class QuotaLiveStore {
    package private(set) var report: QuotaReport = .empty
    package private(set) var isLoading: Bool = true
    package var period: QuotaAnalyzer.Period = .sevenDays {
        didSet { scheduleRefresh(delay: 0) }
    }
    /// Window size in hours when `period == .custom`. Ignored otherwise.
    /// Defaults to 4h — a reasonable "what happened recently" slice.
    package var customHours: Double = 4 {
        didSet {
            guard period == .custom else { return }
            scheduleRefresh(delay: 0)
        }
    }
    /// Explicit from/to dates when `period == .custom`. Takes precedence over
    /// `customHours` while set; nil means "last customHours hours".
    package var customRange: DateInterval? = nil {
        didSet {
            guard period == .custom else { return }
            scheduleRefresh(delay: 0)
        }
    }

    private let projectsDir: URL
    private var rootSource: DispatchSourceFileSystemObject?
    private var dirSources: [URL: DispatchSourceFileSystemObject] = [:]
    private let watchQueue = DispatchQueue(
        label: "io.github.digitalsalve.claudedeck.quota.watch", qos: .utility
    )
    private let analyzeQueue = DispatchQueue(
        label: "io.github.digitalsalve.claudedeck.quota.analyze", qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private var pendingWork: DispatchWorkItem?
    private var pendingDeadline: Date?
    private let stateLock = NSLock()
    private var hasInitialized = false
    private var isAnalyzing = false
    private var needsReanalyze = false
    /// Soft cap on number of project-dir watchers. Prevents FD exhaustion
    /// for users with hundreds of project dirs. Claude Code's default
    /// ulimit on macOS is 256; we leave headroom for the rest of the app.
    private let maxDirWatchers = 180

    package init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        projectsDir = home.appendingPathComponent(".claude/projects")
    }

    deinit {
        stopWatching()
    }

    /// Begin watching and publish the first report. Idempotent, thread-safe.
    package func start() {
        stateLock.lock()
        if hasInitialized { stateLock.unlock(); return }
        hasInitialized = true
        stateLock.unlock()

        // Do setup on watchQueue so startup can't block the caller and all
        // watcher mutations happen on a single serial queue.
        watchQueue.async { [weak self] in
            guard let self else { return }
            self.startRootWatcher()
            self.reconcileProjectWatchers()
            self.scheduleRefresh(delay: 0)
            self.restartTick()
        }
    }

    /// Force a refresh immediately (user tapped refresh button).
    package func refreshNow() {
        scheduleRefresh(delay: 0)
    }

    // MARK: - Watchers

    private func startRootWatcher() {
        let fd = open(projectsDir.path, O_EVTONLY)
        DebugLog.write("[quota] root watcher fd=\(fd) path=\(projectsDir.path)")
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: watchQueue
        )
        src.setEventHandler { [weak self] in
            DebugLog.write("[quota] root event")
            self?.reconcileProjectWatchers()
            self?.scheduleRefresh(delay: 0.5)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        rootSource = src
    }

    private func reconcileProjectWatchers() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return }

        let current = Set(dirs.filter { $0.hasDirectoryPath })

        for dir in current where dirSources[dir] == nil {
            guard dirSources.count < maxDirWatchers else { break } // FD safety cap
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend],
                queue: watchQueue
            )
            src.setEventHandler { [weak self] in
                DebugLog.write("[quota] dir event \(dir.lastPathComponent)")
                self?.scheduleRefresh(delay: 0.5)
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            dirSources[dir] = src
        }
        DebugLog.write("[quota] dir watchers: \(dirSources.count) of \(current.count) dirs")

        for (dir, src) in dirSources where !current.contains(dir) {
            src.cancel()
            dirSources.removeValue(forKey: dir)
        }
    }

    private func stopWatching() {
        tickSource?.cancel()
        tickSource = nil
        rootSource?.cancel()
        rootSource = nil
        for src in dirSources.values { src.cancel() }
        dirSources.removeAll()
    }

    // MARK: - Debounced single-flight analyze

    /// Coalesce rapid file events into a single analyze() run. Multiple
    /// events fire per turn (write metadata, extend data, append newline);
    /// we wait for the burst to finish before parsing.
    ///
    /// Guarantees:
    /// - Only one analyze() runs at a time (single-flight).
    /// - If events arrive during an in-flight analyze, exactly one follow-up
    ///   is queued — never a pile-up regardless of event rate.
    /// - Cancellation of the debounce timer is race-free because both
    ///   scheduling and execution flow through watchQueue.
    /// True while a Quota view is on screen. Off screen, transcript events
    /// are coalesced into one analyze per `backgroundDebounce` so the ledger
    /// keeps booking without re-scanning 2,000+ files every second during
    /// a busy day. An explicit refresh (delay 0) is never slowed.
    package var isVisible: Bool = false {
        didSet {
            if isVisible != oldValue { restartTick() }
            if isVisible && !oldValue { scheduleRefresh(delay: 0) }
        }
    }
    package var backgroundDebounce: TimeInterval = 60
    /// True from an explicit refresh (period change, custom range, button)
    /// until its analyze has published. Drives the header spinner.
    package var isRefreshing: Bool = false

    /// Directory watchers only fire when an entry is created, renamed or
    /// removed; a transcript growing in place never trips them (measured
    /// 2026-10-26: 57 watchers, zero events in 90 s with eight busy
    /// sessions). A periodic tick is what actually keeps the report and the
    /// ledger current. Incremental analyze costs ~0.25 s here.
    package var visibleTick: TimeInterval = 20
    package var backgroundTick: TimeInterval = 300
    package var tickInterval: TimeInterval { isVisible ? visibleTick : backgroundTick }
    private var tickSource: DispatchSourceTimer?

    private func restartTick() {
        watchQueue.async { [weak self] in
            guard let self, self.hasInitialized else { return }
            self.tickSource?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.watchQueue)
            let interval = self.tickInterval
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
            t.setEventHandler { [weak self] in
                DebugLog.write("[quota] tick (\(interval)s)")
                self?.scheduleRefresh(delay: 0)
            }
            t.resume()
            self.tickSource = t
        }
    }

    package func effectiveDelay(for delay: TimeInterval) -> TimeInterval {
        if delay <= 0 || isVisible { return delay }
        return max(delay, backgroundDebounce)
    }

    private func scheduleRefresh(delay requested: TimeInterval) {
        let delay = effectiveDelay(for: requested)
        if requested <= 0 {
            DispatchQueue.main.async { [weak self] in self?.isRefreshing = true }
        }
        watchQueue.async { [weak self] in
            guard let self else { return }
            DebugLog.write("[quota] scheduleRefresh requested=\(requested) effective=\(delay) visible=\(self.isVisible) pending=\(self.pendingDeadline.map { "\($0)" } ?? "none")")
            // Keep an already-pending sooner run; a later event must not
            // push a due analyze further out forever.
            if let pending = self.pendingDeadline, delay > 0, pending <= Date().addingTimeInterval(delay) {
                DebugLog.write("[quota] keep pending run at \(pending)")
                return
            }
            self.pendingWork?.cancel()
            self.pendingDeadline = delay > 0 ? Date().addingTimeInterval(delay) : nil
            let work = DispatchWorkItem { [weak self] in
                DebugLog.write("[quota] work fired")
                self?.watchQueue.async { self?.pendingDeadline = nil }
                self?.runAnalyzeSingleFlight()
            }
            self.pendingWork = work
            if delay <= 0 {
                self.analyzeQueue.async(execute: work)
            } else {
                self.analyzeQueue.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    /// Runs analyze() with single-flight semantics: if one is already in
    /// progress, records that another is needed and returns immediately.
    /// When the in-flight run finishes, it self-reschedules if needed.
    private func runAnalyzeSingleFlight() {
        stateLock.lock()
        if isAnalyzing {
            needsReanalyze = true
            stateLock.unlock()
            return
        }
        isAnalyzing = true
        stateLock.unlock()

        // Read period fresh (didSet may have changed it while we queued).
        let currentPeriod = period
        let currentCustom = customHours
        let currentRange = customRange
        let t0 = Date()
        let result = QuotaAnalyzer.shared.analyze(
            period: currentPeriod,
            customHours: currentCustom,
            customRange: currentRange
        )
        DebugLog.write("[quota] analyze done: \(result.sessions.count) sessions in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.report = result
            self.isLoading = false
            self.isRefreshing = false
        }

        stateLock.lock()
        isAnalyzing = false
        let shouldRerun = needsReanalyze
        needsReanalyze = false
        stateLock.unlock()

        if shouldRerun {
            analyzeQueue.async { [weak self] in
                self?.runAnalyzeSingleFlight()
            }
        }
    }
}
