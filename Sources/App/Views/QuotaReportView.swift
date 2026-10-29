import SwiftUI
import ClaudeDeckCore

/// Centralized sizing so the compact menubar and popped-out window can share
/// one row/header implementation and just swap metrics. Scaling a handful of
/// numbers beats duplicating the whole layout.
private struct QuotaMetrics {
    let fontSize: CGFloat
    let chevronSize: CGFloat
    let headerFontSize: CGFloat
    let indexColWidth: CGFloat
    let turnsColWidth: CGFloat
    let baseColWidth: CGFloat
    let nowColWidth: CGFloat
    let wasteColWidth: CGFloat
    let tokensColWidth: CGFloat
    let barHeight: CGFloat
    let rowVPadding: CGFloat
    let subagentIndent: CGFloat
    let dotsReserve: CGFloat
    let barLeadingPad: CGFloat
    /// Trailing slot reserved on every row for the "N subs ⌄" expand button
    /// (even on rows that don't show it — keeps the bar column stable).
    let expandColWidth: CGFloat
    /// True when there's room to show the "subs" word inside the expand
    /// button. Compact popover = false (pill clips otherwise); popped = true.
    let expandShowsLabel: Bool

    var reservedWidth: CGFloat {
        indexColWidth + turnsColWidth + baseColWidth + nowColWidth
            + wasteColWidth + tokensColWidth + barLeadingPad + dotsReserve
            + expandColWidth
    }

    static let compact = QuotaMetrics(
        fontSize: 10, chevronSize: 9, headerFontSize: 9,
        indexColWidth: 32, turnsColWidth: 42, baseColWidth: 44,
        nowColWidth: 44, wasteColWidth: 44, tokensColWidth: 48,
        barHeight: 12, rowVPadding: 1,
        // Keep identical to root horizontal padding so the bar's computed
        // width (based on the header's available space) stays valid when
        // the row is reused for subagent children. Anything larger caused
        // subagent HStacks to overflow leftward in narrow windows.
        subagentIndent: 16,
        dotsReserve: 17, barLeadingPad: 8,
        // With the wider 540pt popover there's room for the full labelled
        // pill without clipping — matches the popped-out view's affordance.
        expandColWidth: 68,
        expandShowsLabel: true
    )
    static let popped = QuotaMetrics(
        fontSize: 14, chevronSize: 14, headerFontSize: 11,
        indexColWidth: 44, turnsColWidth: 56, baseColWidth: 60,
        nowColWidth: 60, wasteColWidth: 60, tokensColWidth: 68,
        barHeight: 16, rowVPadding: 5,
        subagentIndent: 16,
        dotsReserve: 22, barLeadingPad: 12,
        expandColWidth: 88,
        expandShowsLabel: true
    )
}

struct QuotaReportView: View {
    @Bindable var store: QuotaLiveStore
    /// Width available for each row's bar. Measured once at the list level
    /// and passed down to every row — avoids a per-row GeometryReader which
    /// triggers a layout pass per row on every tab switch and scroll.
    @State private var barWidth: CGFloat = 150
    /// Parent session ids currently expanded inline to reveal their subagents.
    /// View-lifetime only — reopening the window resets everything collapsed.
    @State private var expandedParents: Set<String> = []
    @Environment(\.openWindow) private var openWindow
    /// Whether this instance of the view is hosted inside the popped-out
    /// Quota window. Hides the pop-out button in that context (no point
    /// opening the same window twice) and trims the outer padding.
    let isPoppedOut: Bool

    init(store: QuotaLiveStore, isPoppedOut: Bool = false) {
        self.store = store
        self.isPoppedOut = isPoppedOut
    }

    private var metrics: QuotaMetrics {
        isPoppedOut ? .popped : .compact
    }

    /// Denominator for row bars. Using the report-wide total makes every bar
    /// tiny (worst session is ~5% of total), leaving huge empty space to the
    /// right. Scaling to the largest single session fills the full bar slot
    /// and makes relative sizes immediately legible.
    private var barScaleTokens: Int {
        max(1, store.report.sessions.map { $0.totalTokens }.max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with period selector + pop-out (hidden when already popped out)
            QuotaHeader(
                report: store.report,
                selectedPeriod: $store.period,
                customHours: $store.customHours,
                customRange: $store.customRange,
                isRefreshing: store.isRefreshing,
                onRefresh: store.refreshNow,
                onPopOut: isPoppedOut ? nil : { openWindow(id: "quota") },
                availablePeriods: isPoppedOut
                    ? [.sixHours, .sevenDays, .thirtyDays, .allTime]
                    : [.sevenDays, .thirtyDays, .allTime],
                showsCustom: isPoppedOut
            )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            if store.isLoading {
                Spacer()
                ProgressView("Analyzing sessions...")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if store.report.sessions.isEmpty {
                Spacer()
                Text("No sessions found in \(store.report.periodLabel)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Summary stats
                        QuotaSummarySection(report: store.report)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                        Divider()

                        // Session table
                        QuotaTableHeader(metrics: metrics)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .background {
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear {
                                            updateBarWidth(containerWidth: geo.size.width)
                                        }
                                        .onChange(of: geo.size.width) { _, new in
                                            updateBarWidth(containerWidth: new)
                                        }
                                }
                            }

                        ForEach(store.report.rootSessions) { session in
                            let children = store.report.subagents(of: session.id)
                            let isExpanded = expandedParents.contains(session.id)

                            QuotaSessionRow(
                                session: session,
                                maxTokens: barScaleTokens,
                                barWidth: barWidth,
                                subagentCount: children.count,
                                isExpanded: isExpanded,
                                onToggleExpand: children.isEmpty ? nil : {
                                    toggleExpanded(session.id)
                                },
                                metrics: metrics
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, metrics.rowVPadding)
                            // Subtle highlight on the parent row while its
                            // children are visible — makes it obvious the row
                            // represents the PARENT PORTION only, not a total.
                            .background(
                                isExpanded
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear
                            )

                            if isExpanded {
                                ForEach(children) { child in
                                    QuotaSessionRow(
                                        session: child,
                                        maxTokens: barScaleTokens,
                                        barWidth: barWidth,
                                        subagentCount: 0,
                                        isExpanded: false,
                                        onToggleExpand: nil,
                                        metrics: metrics
                                    )
                                    .padding(.leading, metrics.subagentIndent)
                                    .padding(.trailing, 16)
                                    .padding(.vertical, max(1, metrics.rowVPadding - 2))
                                }

                                // Rollup row closes out the expanded group
                                // so the total reads as a subtotal of what
                                // was just listed above.
                                ParentRollupRow(
                                    parent: session,
                                    children: children,
                                    metrics: metrics
                                )
                                .padding(.horizontal, 16)
                                .padding(.vertical, metrics.rowVPadding)
                                .background(Color.accentColor.opacity(0.04))
                            }
                        }

                        // Subagents whose parent fell outside the current
                        // period — rendered flat so their tokens don't vanish.
                        if !store.report.orphanSubagents.isEmpty {
                            Divider().padding(.vertical, 4)
                            Text("SUBAGENTS (parent outside period)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 2)
                            ForEach(store.report.orphanSubagents) { orphan in
                                QuotaSessionRow(
                                    session: orphan,
                                    maxTokens: barScaleTokens,
                                    barWidth: barWidth,
                                    subagentCount: 0,
                                    isExpanded: false,
                                    onToggleExpand: nil,
                                    metrics: metrics
                                )
                                .padding(.horizontal, 16)
                                .padding(.vertical, max(1, metrics.rowVPadding - 2))
                            }
                        }
                        // Worst session callout
                        if let worst = store.report.worstSession, worst.wasteMultiplier > 1.5 {
                            Divider().padding(.vertical, 6)
                            WorstSessionCallout(session: worst)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }

                        // Savings summary
                        if store.report.potentialSavingsTokens > 0 {
                            Divider().padding(.vertical, 4)
                            SavingsSummary(report: store.report)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }
        }
        .onAppear { store.start(); store.isVisible = true }
        .onDisappear { store.isVisible = false }
    }

    private func updateBarWidth(containerWidth: CGFloat) {
        // 32 = horizontal padding applied by the row (16 * 2). Remaining
        // column widths and bar-related reserve come from the active metrics.
        let reserved: CGFloat = 32 + metrics.reservedWidth
        let available = max(40, containerWidth - reserved)
        if abs(available - barWidth) > 1 { barWidth = available }
    }


    private func toggleExpanded(_ id: String) {
        if expandedParents.contains(id) {
            expandedParents.remove(id)
        } else {
            expandedParents.insert(id)
        }
    }
}

// MARK: - Parent Rollup Row

/// "Σ" summary row placed after a parent's expanded subagents. Shows the
/// parent's own tokens + subagent tokens + the combined total, so users can
/// see at a glance how much of a session's spend came from the main agent
/// vs the sidechains it spawned.
private struct ParentRollupRow: View {
    let parent: QuotaSessionReport
    let children: [QuotaSessionReport]
    let metrics: QuotaMetrics

    private var subTotal: Int {
        children.reduce(0) { $0 + $1.totalTokens }
    }
    private var grandTotal: Int { parent.totalTokens + subTotal }

    var body: some View {
        HStack(spacing: 0) {
            Text("Σ")
                .frame(width: metrics.indexColWidth, alignment: .trailing)
                .foregroundStyle(Color.accentColor)
            Text("TOTAL")
                .frame(width: metrics.turnsColWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text("parent")
                .frame(width: metrics.baseColWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(formatTokens(parent.totalTokens))
                .frame(width: metrics.nowColWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text("+\(children.count) sub\(children.count == 1 ? "" : "s")")
                .frame(width: metrics.wasteColWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(formatTokens(grandTotal))
                .frame(width: metrics.tokensColWidth, alignment: .trailing)
                .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .font(.system(size: metrics.fontSize, weight: .bold, design: .monospaced))
    }
}

// MARK: - Subagent Detail Popover (unused in detached mode — kept for future)

/// Attached popover showing a single parent's subagents. Lives outside the
/// main table's scroll area so expanding a parent with many subagents doesn't
/// shove the rest of the quota view off-screen. Sized to show ~10 rows with
/// its own internal scroll for longer lists.
private struct SubagentDetailPopover: View {
    let parent: QuotaSessionReport
    let children: [QuotaSessionReport]
    let reportTotalTokens: Int

    private var childTokenTotal: Int {
        children.reduce(0) { $0 + $1.totalTokens }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(children.count) SUBAGENT\(children.count == 1 ? "" : "S")")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(formatTokens(childTokenTotal)) tokens across subagents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Parent: \(parent.projectName) · \(parent.turns) turns · \(formatTokens(parent.totalTokens))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(children) { child in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(modelColor(child.model))
                                .frame(width: 5, height: 5)
                            Text("\(child.turns)t")
                                .frame(width: 28, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(formatTokens(child.totalTokens))
                                .frame(width: 60, alignment: .trailing)
                                .foregroundStyle(.primary)
                            // Horizontal bar scaled to the biggest child so
                            // relative sizes within this parent are legible.
                            let maxChild = max(1, children.map { $0.totalTokens }.max() ?? 1)
                            let fraction = Double(child.totalTokens) / Double(maxChild)
                            HStack(spacing: 0) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(modelColor(child.model).opacity(0.7))
                                    .frame(
                                        width: max(2, 100 * CGFloat(fraction)),
                                        height: 8
                                    )
                                Spacer(minLength: 0)
                            }
                            .frame(width: 100)
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 260)
        .padding(.bottom, 8)
    }
}

// MARK: - Header

private struct QuotaHeader: View {
    let report: QuotaReport
    @Binding var selectedPeriod: QuotaAnalyzer.Period
    @Binding var customHours: Double
    @Binding var customRange: DateInterval?
    var isRefreshing: Bool = false
    let onRefresh: () -> Void
    /// Nil when the view is already detached — hides the pop-out affordance
    /// so we don't spawn duplicate windows.
    let onPopOut: (() -> Void)?
    /// Which period chips to render. Compact shows the legacy three; popped
    /// adds 6h/12h/1d/3d for finer-grained slices plus a Custom picker.
    let availablePeriods: [QuotaAnalyzer.Period]
    /// Whether to show the Custom chip. Popped only — no room in compact.
    let showsCustom: Bool

    @State private var customPickerOpen = false

    var body: some View {
        HStack {
            Text("Quota Report")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let popOut = onPopOut {
                Button(action: popOut) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open Quota in its own window")
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(availablePeriods, id: \.rawValue) { period in
                    chipButton(
                        label: period.rawValue,
                        active: selectedPeriod == period
                    ) {
                        selectedPeriod = period
                    }
                }
                if showsCustom {
                    chipButton(
                        label: selectedPeriod == .custom
                            ? (customRange.map(rangeChipLabel) ?? customChipLabel(hours: customHours))
                            : "Custom",
                        active: selectedPeriod == .custom
                    ) {
                        customPickerOpen = true
                        selectedPeriod = .custom
                    }
                    .popover(isPresented: $customPickerOpen, arrowEdge: .top) {
                        CustomPeriodPicker(hours: $customHours, range: $customRange, isPresented: $customPickerOpen)
                    }
                }
            }
            if isRefreshing {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("updating")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
        .animation(.easeInOut(duration: 0.15), value: isRefreshing)
    }

    @ViewBuilder
    private func chipButton(
        label: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: active ? .bold : .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(active ? Color.primary.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func rangeChipLabel(_ r: DateInterval) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: r.start))–\(f.string(from: r.end))"
    }

    private func customChipLabel(hours: Double) -> String {
        if hours >= 24 && hours.truncatingRemainder(dividingBy: 24) == 0 {
            return "\(Int(hours / 24))d"
        }
        if hours == floor(hours) { return "\(Int(hours))h" }
        return String(format: "%.1fh", hours)
    }
}

// MARK: - Custom Period Picker

private struct CustomPeriodPicker: View {
    @Binding var hours: Double
    @Binding var range: DateInterval?
    @Binding var isPresented: Bool
    @State private var valueText: String = ""
    @State private var unit: Unit = .hours
    @State private var mode: Mode = .recent
    @State private var fromDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var toDate: Date = Date()

    enum Mode: String, CaseIterable, Identifiable {
        case recent = "Last…"
        case dates  = "Dates"
        var id: String { rawValue }
    }

    enum Unit: String, CaseIterable, Identifiable {
        case hours = "Hours"
        case days  = "Days"
        var id: String { rawValue }
        var hoursMultiplier: Double { self == .days ? 24 : 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CUSTOM RANGE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode == .dates {
                HStack(spacing: 8) {
                    DatePicker("From", selection: $fromDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                    Text("to").font(.system(size: 10)).foregroundStyle(.secondary)
                    DatePicker("To", selection: $toDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                }
                Text("Sessions whose transcripts are still on disk (Claude Code keeps \(UsageLedger.cleanupPeriodDays()) days). Older totals live in the History panel.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: commitRange) {
                    Text("Apply").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
            } else {
            HStack(spacing: 8) {
                TextField("e.g. 4", text: $valueText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit(commit)
                Picker("Unit", selection: $unit) {
                    ForEach(Unit.allCases) { u in Text(u.rawValue).tag(u) }
                }
                .labelsHidden()
                .frame(width: 90)
                .onChange(of: unit) { _, _ in commitHours() }
            }
            Text("Quick picks")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                quickPick("1h", hours: 1)
                quickPick("2h", hours: 2)
                quickPick("4h", hours: 4)
                quickPick("8h", hours: 8)
                quickPick("48h", hours: 48)
            }
            Button(action: commit) {
                Text("Apply")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            valueText = formatValueForUnit(hours: hours, unit: unit)
            if let r = range { mode = .dates; fromDate = r.start; toDate = r.end }
        }
    }

    /// Whole days: from the start of the first day to the end of the last.
    private func commitRange() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: min(fromDate, toDate))
        let endDay = cal.startOfDay(for: max(fromDate, toDate))
        let end = min(Date(), cal.date(byAdding: .day, value: 1, to: endDay)!.addingTimeInterval(-1))
        range = DateInterval(start: start, end: end)
        isPresented = false
    }

    private func quickPick(_ label: String, hours h: Double) -> some View {
        Button(label) {
            let pickedUnit: Unit = h >= 24 ? .days : .hours
            hours = h
            unit = pickedUnit
            valueText = formatValueForUnit(hours: h, unit: pickedUnit)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func commit() {
        commitHours()
        isPresented = false
    }

    private func commitHours() {
        range = nil
        guard let v = Double(valueText.trimmingCharacters(in: .whitespaces)),
              v > 0 else { return }
        hours = v * unit.hoursMultiplier
    }

    private func formatValueForUnit(hours h: Double, unit: Unit) -> String {
        let v = h / unit.hoursMultiplier
        return v == floor(v) ? String(Int(v)) : String(format: "%.2g", v)
    }
}

// MARK: - Summary

private struct QuotaSummarySection: View {
    let report: QuotaReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(report.totalSessions) sessions  ·  \(formatTokens(report.totalTokens)) tokens total")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            if report.totalThinkingTokens > 0 || report.totalWebRequests > 0 {
                Text(thinkingSummary(report))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if report.sessionsOver5x > 0 {
                Text("\(report.sessionsOver5x) sessions burned 5x+ more quota than necessary")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            if report.sessions3to5x > 0 {
                Text("\(report.sessions3to5x) more sessions used 3\u{2013}5x quota")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Table Header

private struct QuotaTableHeader: View {
    let metrics: QuotaMetrics

    var body: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: metrics.indexColWidth, alignment: .trailing)
            Text("TURNS")
                .frame(width: metrics.turnsColWidth, alignment: .trailing)
            Text("BASE")
                .frame(width: metrics.baseColWidth, alignment: .trailing)
            Text("NOW")
                .frame(width: metrics.nowColWidth, alignment: .trailing)
            Text("WASTE")
                .frame(width: metrics.wasteColWidth, alignment: .trailing)
            Text("TOKENS")
                .frame(width: metrics.tokensColWidth, alignment: .trailing)
            Spacer()
        }
        .font(.system(size: metrics.headerFontSize, weight: .bold, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Session Row

private struct QuotaSessionRow: View {
    let session: QuotaSessionReport
    let maxTokens: Int
    let barWidth: CGFloat
    /// Number of subagent children this parent row owns. 0 for leaves and
    /// for subagent rows themselves.
    let subagentCount: Int
    let isExpanded: Bool
    /// Nil on rows that aren't expandable (leaves, subagent rows). The row
    /// still reserves the disclosure column so columns align across the list.
    let onToggleExpand: (() -> Void)?
    let metrics: QuotaMetrics

    private var barFraction: Double {
        guard maxTokens > 0 else { return 0 }
        return min(1.0, Double(session.totalTokens) / Double(maxTokens))
    }

    private var wasteColor: Color {
        switch session.wasteColor {
        case .critical: return .red
        case .high:     return .orange
        case .moderate: return .yellow
        case .efficient: return .green
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // # column: always the session number for roots; a subtle
            // turn-down arrow for subagent children so they still stand out
            // from their parent.
            Group {
                if session.isSubagent {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: metrics.chevronSize - 2))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(SessionNumberRegistry.shared.number(for: session.id))")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: metrics.indexColWidth, alignment: .trailing)

            // Data columns
            Text("\(session.turns)")
                .frame(width: metrics.turnsColWidth, alignment: .trailing)
                .foregroundStyle(.primary)

            Text(formatK(session.baseInputPerTurn))
                .frame(width: metrics.baseColWidth, alignment: .trailing)
                .foregroundStyle(.secondary)

            Text(formatK(session.currentInputPerTurn))
                .frame(width: metrics.nowColWidth, alignment: .trailing)
                .foregroundStyle(.primary)

            Text(String(format: "%.1fx", session.wasteMultiplier))
                .frame(width: metrics.wasteColWidth, alignment: .trailing)
                .foregroundStyle(wasteColor)

            Text(formatTokens(session.totalTokens))
                .frame(width: metrics.tokensColWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
                .help(tokenBreakdown(session))

            // Bar — flexes to fill whatever space remains after the fixed
            // columns, model dots, and expand pill. A per-row GeometryReader
            // makes the fill width reactive to the actual available width,
            // so tab-switches and window resizes can't desynchronize a
            // shared barWidth state from the true layout.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.clear
                    RoundedRectangle(cornerRadius: 2)
                        .fill(wasteColor.opacity(0.85))
                        .frame(
                            width: max(2, geo.size.width * barFraction),
                            height: metrics.barHeight
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: metrics.barHeight)
            .padding(.leading, metrics.barLeadingPad)

            // Model dot
            Circle()
                .fill(modelColor(session.model))
                .frame(width: metrics.barHeight * 0.5, height: metrics.barHeight * 0.5)
                .padding(.leading, 4)

            // Active indicator
            if session.isActive {
                Circle()
                    .fill(Color.green)
                    .frame(width: metrics.barHeight * 0.42, height: metrics.barHeight * 0.42)
                    .shadow(color: .green.opacity(0.8), radius: 3)
                    .padding(.leading, 2)
            }

            // Expand control — fixed slot on the right so columns stay
            // aligned whether or not the row has children. Labelled with
            // the subagent count so the control reads as "N subagents" not
            // an ambiguous chevron.
            Group {
                if let toggle = onToggleExpand {
                    Button(action: toggle) {
                        if metrics.expandShowsLabel {
                            // Popped: full labelled pill — space allows it.
                            HStack(spacing: 3) {
                                Text("\(subagentCount) sub\(subagentCount == 1 ? "" : "s")")
                                    .font(.system(size: metrics.fontSize - 1, weight: .semibold))
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: metrics.chevronSize, weight: .bold))
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(isExpanded ? 0.18 : 0.10))
                            )
                        } else {
                            // Compact: just an accent-tinted chevron. Count
                            // is omitted — there's genuinely no room for it
                            // in the 440pt popover without clipping.
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: metrics.chevronSize + 2, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: metrics.expandColWidth, alignment: .trailing)
            .padding(.leading, 6)
        }
        .font(.system(size: metrics.fontSize, weight: .medium, design: .monospaced))
        .padding(.vertical, 1)
        // Whole-row hit target so the tiny chevron isn't the only way to
        // expand. contentShape ensures the transparent gaps are tappable.
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleExpand?()
        }
    }

    private func formatK(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Worst Session Callout

private struct WorstSessionCallout: View {
    let session: QuotaSessionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Worst: \(session.projectName) (\(session.turns) turns)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Started at \(formatK(session.baseInputPerTurn))/turn, ended at \(formatK(session.currentInputPerTurn))/turn (\(String(format: "%.1f", session.wasteMultiplier))x waste)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            let idealTokens = session.turns * session.baseInputPerTurn + session.totalOutputTokens
            Text("With rotation, this session would have used ~\(formatTokens(idealTokens)) instead of \(formatTokens(session.totalTokens))")
                .font(.system(size: 10))
                .foregroundStyle(.teal)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatK(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.0fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Savings Summary

private struct SavingsSummary: View {
    let report: QuotaReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("With rotation on all sessions: \(formatTokens(report.withRotationTokens)) tokens instead of \(formatTokens(report.totalTokens))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Text("Potential savings: \(formatTokens(report.potentialSavingsTokens)) tokens (")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.teal)
                Text(String(format: "%.0f%% less quota", report.savingsPercentage))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.teal)
                Text(")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.teal)
            }

            if report.potentialSavingsCost > 0.01 {
                Text(String(format: "~$%.2f estimated savings", report.potentialSavingsCost))
                    .font(.system(size: 10))
                    .foregroundStyle(.teal.opacity(0.8))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Helpers

private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
    if n >= 10_000_000   { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000_000    { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000        { return String(format: "%.0fK", Double(n) / 1_000) }
    return "\(n)"
}

private func modelColor(_ model: String?) -> Color {
    modelFamilyColor(ModelCatalog.shared.family(of: model))
}

/// Tooltip for the tokens column: input vs output, thinking share, web tool calls.
private func thinkingSummary(_ r: QuotaReport) -> String {
    var parts: [String] = []
    if r.totalThinkingTokens > 0, r.totalOutputTokens > 0 {
        let pct = Int(Double(r.totalThinkingTokens) / Double(r.totalOutputTokens) * 100)
        parts.append("\(formatTokens(r.totalThinkingTokens)) of \(formatTokens(r.totalOutputTokens)) output tokens were thinking (\(pct)%)")
    }
    if r.totalWebRequests > 0 { parts.append("\(r.totalWebRequests) web tool calls") }
    return parts.joined(separator: "  ·  ")
}

private func tokenBreakdown(_ s: QuotaSessionReport) -> String {
    var lines = [
        "\(formatTokens(s.totalTokens)) total",
        "\(formatTokens(s.totalInputTokens)) input (incl. cache)",
        "\(formatTokens(s.totalOutputTokens)) output",
    ]
    if s.thinkingTokens > 0 {
        lines.append("  \(formatTokens(s.thinkingTokens)) thinking (\(Int(s.thinkingShare * 100))% of output)")
    }
    if s.webSearchRequests > 0 || s.webFetchRequests > 0 {
        lines.append("\(s.webSearchRequests) web searches · \(s.webFetchRequests) web fetches")
    }
    return lines.joined(separator: "\n")
}

/// One colour per family, shared by every view that badges a model.
func modelFamilyColor(_ family: ModelFamily) -> Color {
    switch family {
    case .fable, .mythos: return .purple
    case .opus:           return .orange
    case .sonnet:         return .blue
    case .haiku:          return .green
    case .unknown:        return .gray
    }
}
