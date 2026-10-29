import SwiftUI
import ClaudeDeckCore

struct ContentView: View {
    @State private var manager = SessionManager()
    @State private var selectedTab: SessionTab = .active
    @State private var dispatchRunning: Bool = false
    @State private var commands = CommandsModel()
    // Owned by ClaudeDeckApp and injected so the detached Quota window
    // shares the same watchers and parsed state — single source of truth.
    @Bindable var quotaStore: QuotaLiveStore

    enum SessionTab { case active, recent, commands, quota }

    var body: some View {
        VStack(spacing: 0) {
            // Launch buttons
            HStack(spacing: 14) {
                LaunchButton(icon: "terminal", label: "New", color: .blue) {
                    TerminalLauncher.launch(.new())
                }
                LaunchButton(icon: "bolt.shield", label: "Dangerous", color: .red) {
                    TerminalLauncher.launch(.new(dangerouslySkipPermissions: true))
                }
                LaunchButton(icon: "arrow.counterclockwise", label: "Resume", color: .purple) {
                    TerminalLauncher.launch(.resume())
                }
                LaunchButton(icon: "play", label: "Continue", color: .green) {
                    TerminalLauncher.launch(.continueRecent)
                }
                DispatchButton(isRunning: dispatchRunning) {
                    DispatchLauncher.launch()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .onAppear { dispatchRunning = DispatchLauncher.isRunning }
            .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in
                dispatchRunning = DispatchLauncher.isRunning
            }

            Divider().padding(.vertical, 4)

            // Usage
            UsageSection(stats: manager.stats) {
                manager.refresh()
            }

            Divider()

            // Tab bar
            HStack(spacing: 0) {
                TabBarButton(
                    label: "Active",
                    badge: manager.activeSessions.isEmpty ? nil : "\(manager.activeSessions.count)",
                    badgeColor: .green,
                    isSelected: selectedTab == .active
                ) { selectedTab = .active }

                TabBarButton(
                    label: "Recent",
                    badge: nil,
                    badgeColor: .secondary,
                    isSelected: selectedTab == .recent
                ) { selectedTab = .recent }

                TabBarButton(
                    label: "Commands",
                    badge: commands.pending.items.isEmpty ? nil : "\(commands.pending.items.count)",
                    badgeColor: .orange,
                    isSelected: selectedTab == .commands
                ) { selectedTab = .commands }

                TabBarButton(
                    label: "Quota",
                    badge: nil,
                    badgeColor: .teal,
                    isSelected: selectedTab == .quota
                ) { selectedTab = .quota }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Divider().padding(.bottom, 2)

            // Session content
            if selectedTab == .quota {
                QuotaReportView(store: quotaStore)
            } else {
                ScrollView {
                    if selectedTab == .active {
                        ActiveSessionsList(sessions: manager.activeSessions,
                                           queued: commands.pending.verb(for:)) { session in
                            manager.killSession(session)
                        } onResume: { session in
                            TerminalLauncher.launch(.resume(sessionId: session.id), cwd: session.cwd)
                        }
                    } else if selectedTab == .commands {
                        CommandsList(entries: commands.entries, sessions: manager.activeSessions)
                    } else {
                        RecentSessionsList(sessions: manager.recentSessions) { session in
                            TerminalLauncher.launch(.resume(sessionId: session.id))
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("ClaudeDeck v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 10))
                        Text("Quit")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(width: 540, height: 650)
        .background(.ultraThickMaterial)
        .onAppear { commands.reload(sessions: manager.activeSessions) }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            commands.reload(sessions: manager.activeSessions)
        }
    }
}

// MARK: - Tab Bar Button

struct TabBarButton: View {
    let label: String
    let badge: String?
    let badgeColor: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badgeColor.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(badgeColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.primary.opacity(0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Usage Section

struct UsageSection: View {
    let stats: UsageStats
    let onRefresh: () -> Void
    @AppStorage("claudePlan") private var planRaw: String = ClaudePlan.pro.rawValue
    @AppStorage("weeklyAllResetAnchor")    private var allResetAnchor:    Double = 0
    @State private var showingResetConfig = false
    @State private var showingModels = false
    @State private var showingHistory = false
    @State private var showingCLI = false
    @State private var statusLineMessage: String? = nil

    private var plan: ClaudePlan { ClaudePlan(rawValue: planRaw) ?? .pro }

    /// Returns next reset label "Resets Wed 3:00 PM" by advancing anchor by 7-day increments
    private func nextResetLabel(anchor: Double) -> String? {
        guard anchor > 0 else { return nil }
        var next = Date(timeIntervalSince1970: anchor)
        let now = Date()
        while next <= now { next = next.addingTimeInterval(7 * 24 * 3600) }
        let df = DateFormatter(); df.dateFormat = "EEE h:mm a"
        return "Resets \(df.string(from: next))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {

            // ── Header ────────────────────────────────────────────────────────
            HStack {
                Text("Peak Hour Tracker")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                HStack(spacing: 8) {
                    if stats.activeSessions > 0 {
                        Text("\(stats.activeSessions) active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    Menu {
                        ForEach(ClaudePlan.allCases) { p in
                            Button(p.rawValue) { planRaw = p.rawValue }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(plan.rawValue)
                                .font(.system(size: 10, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    ModelsButton(isPresented: $showingModels)
                    HistoryButton(isPresented: $showingHistory)
                    CLIButton(isPresented: $showingCLI)
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // ── Peak Hours Timeline ───────────────────────────────────────────
            PeakHoursTimeline(isPeak: stats.isPeakHours)

            // ── Plan Usage Limits ─────────────────────────────────────────────
            HStack(spacing: 6) {
                Text("Plan Usage Limits")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                usageSourceTag
            }
            .padding(.top, 2)

            if let live = stats.usageWindows, !live.isEmpty {
                liveBars(live)
            } else {
                estimatedBars
                statusLineConnect
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Live windows (Claude Code rate_limits via the status line hook)

    @ViewBuilder
    private func liveBars(_ live: UsageWindows) -> some View {
        let now = Date()
        if let w = live.fiveHour?.current(now: now) {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("Current session (5h)")
                PlanLimitBar(used: Double(w.usedPercentage), limit: 100,
                             rightLabel: resetCountdown(w, now: now), unit: .percent)
            }
        }
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel("Weekly limits")
            if let w = live.sevenDay?.current(now: now) {
                PlanLimitBar(used: Double(w.usedPercentage), limit: 100,
                             rightLabel: "All models · " + resetDay(w), unit: .percent)
            }
            ForEach(live.extraWindows, id: \.key) { item in
                let w = item.window.current(now: now)
                PlanLimitBar(used: Double(w.usedPercentage), limit: 100,
                             rightLabel: prettyWindowKey(item.key) + " · " + resetDay(w), unit: .percent)
            }
        }
    }

    /// Fallback when no Claude Code session has written rate_limits yet:
    /// output-token estimate against community plan-unit tables.
    @ViewBuilder
    private var estimatedBars: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel("Current session (estimated)")
            PlanLimitBar(
                used: stats.fiveHourTokens,
                limit: plan.sessionOutputTokenLimit,
                rightLabel: sessionResetLabel(stats),
                unit: .tokens
            )
        }
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionLabel("Weekly limit (estimated)")
                Spacer()
                Button { showingResetConfig.toggle() } label: {
                    Image(systemName: "clock.badge.gear")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Set the weekly reset time")
                .popover(isPresented: $showingResetConfig, arrowEdge: .trailing) {
                    WeeklyResetConfigView(allAnchor: $allResetAnchor)
                }
            }
            PlanLimitBar(
                used: stats.sevenDayAllTokens,
                limit: plan.weeklyAllOutputTokenLimit,
                rightLabel: "All models" + (nextResetLabel(anchor: allResetAnchor).map { " · \($0)" } ?? ""),
                unit: .tokens
            )
        }
    }

    /// Shown with the estimate: live numbers need Claude Code's status line to
    /// run `claudedeck statusline`. One click points it there (the user's own
    /// status line, if any, keeps its display through `--then`).
    @ViewBuilder
    private var statusLineConnect: some View {
        let state = StatusLineSetup.currentState()
        let cliPresent = FileManager.default.isExecutableFile(atPath: StatusLineSetup.defaultCLIPath)
        if let message = statusLineMessage {
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .installed = state {
            Text("Status line connected. Live numbers appear after the next Claude Code message.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if cliPresent {
            HStack(spacing: 6) {
                Button("Connect live usage") { connectStatusLine() }
                    .controlSize(.small)
                Text("Sets Claude Code's status line to ClaudeDeck; backs up settings.json")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func connectStatusLine() {
        do {
            let result = try StatusLineSetup.apply { text in
                try StatusLineSetup.install(text, cli: StatusLineSetup.defaultCLIPath, replace: false)
            }
            let backup = result.backup.map { " Backup: \($0.lastPathComponent)." } ?? ""
            statusLineMessage = "Status line connected. Live numbers appear after the next Claude Code message." + backup
        } catch {
            statusLineMessage = "Could not connect the status line: \(error)"
        }
        onRefresh()
    }

    /// "live · 2m ago" when Claude Code numbers are in use, "estimated"
    /// otherwise. The tooltip explains where the numbers come from.
    private var usageSourceTag: some View {
        let live = stats.usageWindows
        let isLive = live.map { !$0.isEmpty } ?? false
        let age = live?.age() ?? 0
        let ageText: String = {
            guard isLive, age >= 600 else { return "" }
            let h = Int(age) / 3600, m = (Int(age) % 3600) / 60
            return h > 0 ? " · \(h)h ago" : " · \(m)m ago"
        }()
        return Text((isLive ? "live" : "estimated") + ageText)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((isLive ? Color.green : Color.orange).opacity(0.12))
            .clipShape(Capsule())
            .foregroundStyle(isLive ? Color.green : Color.orange)
            .help(isLive
                  ? "Percentages reported by Claude Code for the signed-in account (status line rate_limits), last written \(Int(age / 60))m ago by a running session."
                  : "No live numbers yet. Showing an output-token estimate against the selected plan. Live numbers come from Claude Code's status line running `claudedeck statusline` (Connect live usage below, or `claudedeck statusline --install`).")
    }

    private func resetCountdown(_ w: UsageWindow, now: Date) -> String {
        let secs = w.secondsUntilReset(now: now)
        guard secs > 60 else { return "Resets now" }
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }

    private func resetDay(_ w: UsageWindow) -> String {
        let df = DateFormatter(); df.dateFormat = "EEE h:mm a"
        return "Resets \(df.string(from: w.resetsAt))"
    }

    private func prettyWindowKey(_ key: String) -> String {
        key.replacingOccurrences(of: "seven_day_", with: "")
           .replacingOccurrences(of: "_", with: " ")
           .capitalized
    }

    private func sessionResetLabel(_ s: UsageStats) -> String {
        guard s.windowIsActive else { return "No active window" }
        guard let secs = s.windowSecondsRemaining, secs > 60 else {
            // Active sessions exist but no startedAt timestamp available
            return "\(s.activeSessions) session\(s.activeSessions == 1 ? "" : "s") active"
        }
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }

}

// MARK: - CLI help

private struct CLIButton: View {
    @Binding var isPresented: Bool
    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Command line: claudedeck ping / sessions / spawn / compact / clear / usage")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) { CLIHelpPanel() }
    }
}

private struct CLIHelpPanel: View {
    private let cliPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/bin/claudedeck").path
    private let socketOK = FileManager.default.fileExists(atPath: ControlProtocol.socketPath)
    private let cliOK = FileManager.default.isExecutableFile(
        atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/bin/claudedeck").path)

    private let rows: [(String, String)] = [
        ("ping", "is the app running; which session you are"),
        ("sessions [--json]", "live sessions: status, tty, pid, name, cwd"),
        ("spawn <dir> [--agent NAME] [--prompt TEXT]", "start a new Claude Code session"),
        ("compact [--session ID] [--wake TEXT|--no-wake]", "schedule /compact (your own session by default)"),
        ("clear [--session ID]", "schedule /clear"),
        ("usage [--days N] [--json]", "token history from the ledger"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Command line")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                Circle().fill(cliOK ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(cliPath)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(socketOK ? "socket up" : "socket down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(socketOK ? .green : .red)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows, id: \.0) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Text("claudedeck " + r.0)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(width: 250, alignment: .leading)
                        Text(r.1)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("Sessions act on themselves freely. Acting on another session (--session) needs the orchestrator role and a live owner grant; free wake text is refused on peers. Every request is logged to ~/.claude/claudedeck-commands.log. When the app is not running the CLI falls back to the scripts for self-targeted work.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("README: github.com/DigitalSalve/claude-deck")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 520)
    }
}

// MARK: - Usage history (ledger)

private struct HistoryButton: View {
    @Binding var isPresented: Bool
    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Token history (kept by ClaudeDeck beyond Claude Code's transcript retention)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) { UsageHistoryPanel() }
    }
}

private struct UsageHistoryPanel: View {
    private let ledger = UsageLedger.shared
    private let retention = UsageLedger.cleanupPeriodDays()

    var body: some View {
        let months = ledger.monthly()
        let last30 = ledger.totals(lastDays: 30)
        VStack(alignment: .leading, spacing: 10) {
            Text("Token history")
                .font(.system(size: 12, weight: .semibold))

            Text(retentionLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if months.isEmpty {
                Text("Nothing booked yet. The ledger fills as transcripts are parsed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                section("Last 30 days", last30)
                ForEach(months.prefix(12), id: \.month) { m in
                    section(m.month, m.byModel)
                }
            }

            Text("Ledger: ~/.claude/claudedeck-ledger.json · also `claudedeck usage`")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 420)
    }

    private var retentionLine: String {
        var s = "Claude Code keeps transcripts \(retention) days (cleanupPeriodDays). "
        if let first = ledger.firstDay {
            s += "ClaudeDeck has booked \(ledger.dayCount) day\(ledger.dayCount == 1 ? "" : "s") since \(first), and keeps them."
        } else {
            s += "ClaudeDeck keeps a per-day, per-model ledger that survives the sweep."
        }
        return s
    }

    @ViewBuilder
    private func section(_ title: String, _ byModel: [String: LedgerTotals]) -> some View {
        let total = ledger.grand(byModel)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(fmt(total.allTokens)) tokens · \(fmt(total.output)) out · $\(String(format: "%.2f", total.cost)) · \(total.sessions) sessions")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ForEach(byModel.keys.sorted(), id: \.self) { model in
                let t = byModel[model]!
                let info = ModelCatalog.shared.resolve(model)
                HStack(spacing: 6) {
                    Circle().fill(modelFamilyColor(info.family)).frame(width: 6, height: 6)
                    Text(info.displayName).font(.system(size: 10))
                    Spacer()
                    Text("\(fmt(t.allTokens)) · \(fmt(t.output)) out · $\(String(format: "%.2f", t.cost))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }
}

// MARK: - Models panel (DS-41)

/// Header button that opens the model pricing panel. Shows a count badge
/// when sessions used ids the catalog has no exact price for.
private struct ModelsButton: View {
    @Binding var isPresented: Bool
    @State private var unpriced: Int = 0

    var body: some View {
        Button { unpriced = ModelCatalog.shared.unpricedIdsSeen().count; isPresented.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                if unpriced > 0 {
                    Text("\(unpriced)")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(unpriced > 0 ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(unpriced > 0
              ? "\(unpriced) model id\(unpriced == 1 ? "" : "s") without exact pricing"
              : "Models seen and their pricing")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) { ModelPricingPanel() }
        .onAppear { unpriced = ModelCatalog.shared.unpricedIdsSeen().count }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            unpriced = ModelCatalog.shared.unpricedIdsSeen().count
        }
    }
}

private struct ModelPricingPanel: View {
    private let models = ModelCatalog.shared.idsSeen()
    private let overridePath = ModelCatalog.defaultOverridesURL.path

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models seen this run")
                .font(.system(size: 12, weight: .semibold))

            if models.isEmpty {
                Text("No sessions parsed yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(models.indices, id: \.self) { i in
                        let m = models[i]
                        HStack(spacing: 6) {
                            Circle().fill(modelFamilyColor(m.family)).frame(width: 7, height: 7)
                            Text(m.displayName)
                                .font(.system(size: 11, weight: .medium))
                            Text(m.id ?? "")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(priceLabel(m))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(m.pricingSource == .exact ? Color.secondary : Color.orange)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Add or correct a model")
                    .font(.system(size: 11, weight: .semibold))
                Text("Ids marked ~ use their family's newest rates; ids marked — are unpriced. Put exact rates in:")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(overridePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") { revealOverrideFile() }
                        .font(.system(size: 10))
                        .controlSize(.small)
                }
                Text(#"{"claude-opus-6": {"family":"opus","displayName":"Opus 6","input":4,"output":20}}"#)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Text("Rates are USD per million tokens. Restart ClaudeDeck after editing.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func priceLabel(_ m: ModelInfo) -> String {
        switch m.pricingSource {
        case .exact:          return String(format: "$%g / $%g", m.pricing.input, m.pricing.output)
        case .familyFallback: return String(format: "~$%g / $%g", m.pricing.input, m.pricing.output)
        case .none:           return "—"
        }
    }

    /// Creates an empty override file on first use so Reveal has a target.
    private func revealOverrideFile() {
        let url = ModelCatalog.defaultOverridesURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("{\n}\n".utf8).write(to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Sub-components

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct WeeklyRow: View {
    let label: String
    let tokens: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
            Spacer()
            Text(formatTokens(tokens) + " (7d)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000    { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Reusable progress bar

// MARK: - Weekly Reset Config

struct WeeklyResetConfigView: View {
    @Binding var allAnchor: Double

    @State private var allDate: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weekly Reset Time")
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("All models").font(.system(size: 11)).foregroundStyle(.secondary)
                DatePicker("", selection: $allDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .onChange(of: allDate) { allAnchor = allDate.timeIntervalSince1970 }
            }

            Text("Only used for the estimate. Once a Claude Code session\nreports its rate limits, the real reset time is shown.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            if allAnchor > 0 { allDate = Date(timeIntervalSince1970: allAnchor) }
        }
    }
}

enum BarUnit { case tokens, dollars, percent }

struct PlanLimitBar: View {
    let used: Double
    let limit: Double
    let rightLabel: String
    let unit: BarUnit

    init(used: Int, limit: Int, rightLabel: String, unit: BarUnit) {
        self.used = Double(used); self.limit = Double(limit)
        self.rightLabel = rightLabel; self.unit = unit
    }
    init(used: Double, limit: Double, rightLabel: String, unit: BarUnit) {
        self.used = used; self.limit = limit
        self.rightLabel = rightLabel; self.unit = unit
    }

    private var fraction: Double { guard limit > 0 else { return 0 }; return min(used / limit, 1.0) }
    private var pct: Int { Int(fraction * 100) }
    private var barColor: Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return .blue
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(usedLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(barColor)
                Spacer()
                Text(rightLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.09)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(barColor)
                        .frame(width: geo.size.width * fraction, height: 6)
                        .animation(.easeOut(duration: 0.4), value: fraction)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(barColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var usedLabel: String {
        switch unit {
        case .tokens:
            let u = formatTok(Int(used)), l = formatTok(Int(limit))
            return "\(u) / \(l)  ·  \(pct)%"
        case .dollars:
            return String(format: "$%.2f / $%.0f  ·  %d%%", used, limit, pct)
        case .percent:
            return "\(Int(used))% used"
        }
    }

    private func formatTok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000    { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Peak Hours Timeline

struct PeakHoursTimeline: View {
    let isPeak: Bool

    /// Returns (peakStart, peakEnd) as fractional hours (0–24) in the *local* timezone
    private func localPeakRange() -> (Double, Double) {
        let ptTZ    = TimeZone(identifier: "America/Los_Angeles")!
        var ptCal   = Calendar(identifier: .gregorian); ptCal.timeZone = ptTZ
        var locCal  = Calendar(identifier: .gregorian); locCal.timeZone = TimeZone.current
        let now     = Date()

        // Midnight today in PT
        let midnightPT = ptCal.startOfDay(for: now)
        let peakStartDate = midnightPT.addingTimeInterval(5  * 3600)  // 5 AM PT
        let peakEndDate   = midnightPT.addingTimeInterval(11 * 3600)  // 11 AM PT

        // Express as offset from local midnight
        let midnightLocal = locCal.startOfDay(for: now)
        let pStart = peakStartDate.timeIntervalSince(midnightLocal) / 3600
        let pEnd   = peakEndDate.timeIntervalSince(midnightLocal)   / 3600
        return (pStart, pEnd)
    }

    private var currentHourFraction: Double {
        let cal = Calendar.current
        let h = Double(cal.component(.hour,   from: Date()))
        let m = Double(cal.component(.minute, from: Date()))
        return (h + m / 60) / 24
    }

    private func localTimeLabel(_ hour: Double) -> String {
        let h = Int(hour) % 24
        if h == 0  { return "12a" }
        if h == 12 { return "12p" }
        return h < 12 ? "\(h)a" : "\(h - 12)p"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let (pStart, pEnd) = localPeakRange()
            let pStartF = max(0, min(1, pStart / 24))
            let pEndF   = max(0, min(1, pEnd   / 24))
            let nowF    = currentHourFraction

            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        // Off-peak zones (bright green)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green.opacity(0.55))
                            .frame(height: 8)
                        // Peak zone overlay (yellow)
                        Rectangle()
                            .fill(Color.yellow.opacity(isPeak ? 0.70 : 0.50))
                            .frame(width: (pEndF - pStartF) * w, height: 8)
                            .offset(x: pStartF * w)
                        // Current time needle
                        ZStack {
                            // Glow halo
                            Rectangle()
                                .fill(Color.white.opacity(0.35))
                                .frame(width: 6, height: 14)
                                .blur(radius: 2)
                            // Solid needle
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 3, height: 14)
                        }
                        .offset(x: nowF * w - 1.5)
                        .shadow(color: .white.opacity(0.9), radius: 3, x: 0, y: 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 8)

                // Labels row
                HStack(spacing: 0) {
                    Text("12a")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    // 1x label anchored just right of midnight
                    Text(" 1×")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.green.opacity(0.8))
                    Spacer()
                    Text(localTimeLabel(pStart) + "–" + localTimeLabel(pEnd))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isPeak ? Color.yellow : Color.yellow.opacity(0.7))
                    Text(" 2×")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isPeak ? Color.yellow : Color.yellow.opacity(0.7))
                    Spacer()
                    Text("12a")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isPeak ? Color.yellow.opacity(0.06) : Color.green.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Tooltip for the row preview line: title, opening prompt, latest prompt.
func sessionPreviewHelp(title: String?, first: String?, last: String?) -> String {
    var parts: [String] = []
    if let title { parts.append(title) }
    if let first { parts.append("First: \(first)") }
    if let last, last != first { parts.append("Latest: \(last)") }
    return parts.joined(separator: "\n\n")
}

// MARK: - Dispatch Button

struct DispatchButton: View {
    let isRunning: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isRunning
                              ? Color.teal.opacity(0.30)
                              : Color.teal.opacity(isHovering ? 0.25 : 0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.teal)
                        .frame(width: 56, height: 56)
                    // Live indicator dot — pulsing green when running
                    Circle()
                        .fill(isRunning ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 9, height: 9)
                        .shadow(color: isRunning ? .green.opacity(0.9) : .clear, radius: 4)
                        .padding(6)
                }
                Text("Dispatch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .help(isRunning ? "Dispatch running — click to focus" : "Start dispatch session")
    }
}

// MARK: - Launch Button

struct LaunchButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(isHovering ? 0.25 : 0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

// MARK: - Source Badge (Terminal/Desktop/Web)

// MARK: - Active Sessions

struct ActiveSessionsList: View {
    let sessions: [ClaudeSession]
    var queued: (String) -> String? = { _ in nil }
    let onKill: (ClaudeSession) -> Void
    let onResume: (ClaudeSession) -> Void

    /// Comma-separated archived session IDs persisted across launches
    @AppStorage("archivedSessionIds") private var archivedRaw: String = ""
    @State private var showArchived = false

    private var archivedIds: Set<String> {
        Set(archivedRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private func toggleArchive(_ id: String) {
        var ids = archivedIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        archivedRaw = ids.joined(separator: ",")
    }

    private var visible:  [ClaudeSession] { sessions.filter { !archivedIds.contains($0.id) } }
    private var archived: [ClaudeSession] { sessions.filter {  archivedIds.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Active Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !sessions.isEmpty {
                    Text("\(visible.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Non-archived sessions
            if visible.isEmpty && archived.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ForEach(visible) { session in
                    ActiveSessionRow(
                        session: session,
                        isArchived: false,
                        queuedVerb: queued(session.id),
                        onKill: onKill,
                        onResume: onResume,
                        onToggleArchive: { toggleArchive(session.id) }
                    )
                }
            }

            // Archived section (collapsible)
            if !archived.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showArchived.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                        Text("Archived (\(archived.count))")
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                if showArchived {
                    ForEach(archived) { session in
                        ActiveSessionRow(
                            session: session,
                            isArchived: true,
                            queuedVerb: queued(session.id),
                            onKill: onKill,
                            onResume: onResume,
                            onToggleArchive: { toggleArchive(session.id) }
                        )
                    }
                }
            }
        }
    }
}

struct ActiveSessionRow: View {
    let session: ClaudeSession
    let isArchived: Bool
    var queuedVerb: String? = nil
    let onKill: (ClaudeSession) -> Void
    let onResume: (ClaudeSession) -> Void
    let onToggleArchive: () -> Void

    /// busy = model running (green), idle = waiting on you (yellow),
    /// shell = foreground command (blue), unknown = older Claude Code (green).
    private var statusColor: Color {
        switch session.sessionStatus {
        case .busy:    return .green
        case .idle:    return .yellow
        case .shell:   return .blue
        case .unknown: return .green
        }
    }

    private var statusHelp: String {
        var parts: [String] = []
        switch session.sessionStatus {
        case .busy:    parts.append("Busy: Claude is working")
        case .idle:    parts.append("Idle: waiting for your input")
        case .shell:   parts.append("Running a shell command")
        case .unknown: parts.append("Running")
        }
        if let v = session.claudeVersion { parts.append("Claude Code \(v)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isArchived ? Color.secondary : statusColor)
                .frame(width: 8, height: 8)
                .help(statusHelp)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("#\(SessionNumberRegistry.shared.number(for: session.id))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isArchived ? .secondary : .primary)
                        .help(session.name != nil ? "\(session.cwd)" : session.cwd)
                    Text(session.sourceLabel)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(session.sourceColor.opacity(isArchived ? 0.07 : 0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(session.sourceColor.opacity(isArchived ? 0.5 : 1))
                    if session.sessionStatus != .unknown {
                        Text(session.sessionStatus.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(statusColor.opacity(isArchived ? 0.07 : 0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(statusColor.opacity(isArchived ? 0.5 : 1))
                    }
                    if let queuedVerb {
                        Text("\(queuedVerb) queued")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.orange)
                            .help("/\(queuedVerb) was scheduled through ClaudeDeck; it is typed when this session is next idle")
                    }
                }
                if let preview = session.preview {
                    Text(preview)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isArchived ? .tertiary : .secondary)
                        .help(sessionPreviewHelp(title: session.title, first: session.firstPrompt, last: session.lastPrompt))
                }
                HStack(spacing: 6) {
                    if let date = session.startDate {
                        Text(date, style: .relative)
                    }
                    if let pid = session.pid {
                        Text("PID \(pid)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // Archive toggle — shown for Desktop/Web sessions (CLI gets terminal button instead)
            if !session.isCLI {
                Button(action: onToggleArchive) {
                    Image(systemName: isArchived ? "arrow.uturn.up.circle" : "archivebox")
                        .font(.system(size: 12))
                        .foregroundStyle(isArchived ? Color.blue : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isArchived ? "Unarchive session" : "Archive session")
            }

            // CLI sessions: terminal resume button
            if session.isCLI {
                Button { onResume(session) } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Resume in Warp")
            }

            // Kill button — always shown
            Button { onKill(session) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red.opacity(isArchived ? 0.3 : 0.6))
            }
            .buttonStyle(.plain)
            .help("Kill session")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .opacity(isArchived ? 0.6 : 1.0)
    }
}

// MARK: - Recent Sessions

struct RecentSessionsList: View {
    let sessions: [SessionHistory]
    let onResume: (SessionHistory) -> Void

    @AppStorage("archivedSessionIds") private var archivedRaw: String = ""
    @State private var showArchived = false

    private var archivedIds: Set<String> {
        Set(archivedRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }
    private func toggleArchive(_ id: String) {
        var ids = archivedIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        archivedRaw = ids.joined(separator: ",")
    }

    private var visible:  [SessionHistory] { sessions.filter { !archivedIds.contains($0.id) }.prefix(15).map{$0} }
    private var archived: [SessionHistory] { sessions.filter {  archivedIds.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            ForEach(visible) { session in
                RecentSessionRow(
                    session: session,
                    isArchived: false,
                    onResume: onResume,
                    onToggleArchive: { toggleArchive(session.id) }
                )
            }

            if !archived.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showArchived.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                        Text("Archived (\(archived.count))")
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                if showArchived {
                    ForEach(archived) { session in
                        RecentSessionRow(
                            session: session,
                            isArchived: true,
                            onResume: onResume,
                            onToggleArchive: { toggleArchive(session.id) }
                        )
                    }
                }
            }
        }
    }
}

struct RecentSessionRow: View {
    let session: SessionHistory
    let isArchived: Bool
    let onResume: (SessionHistory) -> Void
    let onToggleArchive: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(modelColor(session.model))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("#\(SessionNumberRegistry.shared.number(for: session.id))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isArchived ? .secondary : .primary)
                    Text(session.sourceLabel)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(session.sourceColor.opacity(isArchived ? 0.07 : 0.12))
                        .clipShape(Capsule())
                        .foregroundStyle(session.sourceColor.opacity(isArchived ? 0.5 : 1))
                    Text(shortModel(session.model))
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(modelColor(session.model).opacity(isArchived ? 0.07 : 0.12))
                        .clipShape(Capsule())
                        .foregroundStyle(modelColor(session.model).opacity(isArchived ? 0.5 : 1))
                        .help(modelHelp(session.model))
                }
                if let preview = session.preview {
                    Text(preview)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isArchived ? .tertiary : .secondary)
                        .help(sessionPreviewHelp(title: session.title, first: session.firstPrompt, last: session.lastPrompt))
                }
                HStack(spacing: 8) {
                    Text(session.lastActivity, style: .relative)
                    Text("\(session.messageCount) msgs")
                    Text(formatPlanUnits(session.totalOutputTokens / 10))
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if isHovering {
                HStack(spacing: 6) {
                    // Archive toggle for Desktop/Web; resume for CLI
                    if session.isCLI {
                        Button {
                            onResume(session)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 9))
                                Text("Resume")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("Resume in Warp")
                    } else {
                        Button(action: onToggleArchive) {
                            Image(systemName: isArchived ? "arrow.uturn.up.circle" : "archivebox")
                                .font(.system(size: 12))
                                .foregroundStyle(isArchived ? Color.blue : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isArchived ? "Unarchive" : "Archive")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .opacity(isArchived ? 0.6 : 1.0)
        .background(isHovering ? Color.primary.opacity(0.05) : .clear)
        .onHover { isHovering = $0 }
    }

    private func formatPlanUnits(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM units", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK units", Double(n) / 1_000) }
        return "\(n) units"
    }

    private func shortModel(_ model: String?) -> String {
        ModelCatalog.shared.resolve(model).shortLabel
    }

    private func modelColor(_ model: String?) -> Color {
        modelFamilyColor(ModelCatalog.shared.family(of: model))
    }

    /// Tooltip: full name, plus a pricing note when the id is not in the table.
    private func modelHelp(_ model: String?) -> String {
        let info = ModelCatalog.shared.resolve(model)
        switch info.pricingSource {
        case .exact:          return info.displayName
        case .familyFallback: return "\(info.displayName) — unpriced id \(info.id ?? ""); using \(info.family.label) family rates. Add it to ~/.claude/claudedeck-models.json"
        case .none:           return "\(info.displayName) — unknown model, cost not estimated. Add it to ~/.claude/claudedeck-models.json"
        }
    }
}
