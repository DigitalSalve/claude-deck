import SwiftUI
import AppKit
import ClaudeDeckCore

// MARK: - Launch intent

/// What a launch button is about to do, for the picker's header.
struct LaunchIntent {
    let mode: LaunchMode
    let title: String
    let icon: String
    let color: Color

    static let new = LaunchIntent(mode: .new(), title: "New session",
                                  icon: "terminal", color: .blue)
    static let dangerous = LaunchIntent(mode: .new(dangerouslySkipPermissions: true),
                                        title: "New session, permissions off",
                                        icon: "bolt.shield", color: .red)
    static let resume = LaunchIntent(mode: .resume(), title: "Resume a session",
                                     icon: "arrow.counterclockwise", color: .purple)
    static let continueRecent = LaunchIntent(mode: .continueRecent, title: "Continue last session",
                                             icon: "play", color: .green)

    var subtitle: String {
        switch mode {
        case .new: return "Where should it run?"
        case .resume: return "Which project's sessions?"
        case .continueRecent: return "Which project's last session?"
        }
    }
}

// MARK: - Picker

/// Asked on every launch: the folder to run Claude Code in. Type to filter,
/// arrow keys to move, Return to launch, Escape to cancel. Home and any other
/// folder are one click away in the bar under the search field.
struct LaunchFolderPicker: View {
    let intent: LaunchIntent
    @Binding var catalog: RepoCatalog
    /// Claude Code project keys of recent sessions, most recent first.
    let recentProjectKeys: [String]
    let onLaunch: (String) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var repos: [RepoEntry] = []
    @State private var highlighted: String?
    /// Only keyboard moves scroll the list; scrolling on hover would move
    /// rows under the pointer and chase the mouse.
    @State private var scrollToHighlight = false
    @State private var now = Date()
    @FocusState private var searchFocused: Bool

    private var home: RepoEntry { RepoEntry(path: NSHomeDirectory()) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var pinnedOnly: [RepoEntry] {
        let scanned = Set(repos.map(\.path))
        return catalog.pinnedEntries().filter { !scanned.contains($0.path) }
    }

    /// Launched from the deck first, then repositories matched to recent
    /// Claude Code sessions, capped so the list stays scannable.
    private var recent: [RepoEntry] {
        var seen = Set<String>()
        var out: [RepoEntry] = []
        let fromSessions = RepoCatalog.matchRecent(projectKeys: recentProjectKeys,
                                                   candidates: repos + catalog.pinnedEntries())
        for entry in catalog.recentEntries() + fromSessions
        where entry.path != home.path && seen.insert(entry.path).inserted {
            out.append(entry)
        }
        return Array(out.prefix(RepoCatalog.recentLimit))
    }

    private var matches: [RepoEntry] { RepoCatalog.filter(pinnedOnly + repos, query: query) }

    private struct RowGroup: Identifiable {
        let title: String?
        let entries: [RepoEntry]
        var id: String { title ?? "matches" }
    }

    private var sections: [RowGroup] {
        if searching { return [RowGroup(title: nil, entries: matches)] }
        var out: [RowGroup] = []
        if !recent.isEmpty { out.append(RowGroup(title: "Recent", entries: recent)) }
        if !pinnedOnly.isEmpty { out.append(RowGroup(title: "Chosen folders", entries: pinnedOnly)) }
        out.append(RowGroup(title: "All repositories", entries: repos))
        return out
    }

    /// Every visible row in order, for keyboard movement.
    private var ordered: [RepoEntry] {
        var seen = Set<String>()
        return sections.flatMap(\.entries).filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            actionBar
            Divider()
            list
        }
        .frame(width: 480)
        .onAppear {
            repos = catalog.scanRepos()
            now = Date()
            highlighted = ordered.first?.path
            searchFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = ordered.first?.path }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(intent.color.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: intent.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(intent.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(intent.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(intent.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search repositories", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { launchHighlighted() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if searching && matches.isEmpty {
                        emptyState("No folder matches “\(query.trimmingCharacters(in: .whitespaces))”",
                                   hint: "Try fewer letters, or use Other Folder… above.")
                    } else if repos.isEmpty && !searching && pinnedOnly.isEmpty && recent.isEmpty {
                        emptyState("No git repositories under \(catalog.roots.joined(separator: ", "))",
                                   hint: "Add a scan root from the ⋯ menu above, or pick any folder.")
                    }
                    ForEach(sections) { section in
                        if let title = section.title, !section.entries.isEmpty {
                            Text(title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 20)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                        ForEach(section.entries) { entry in
                            LaunchFolderRow(
                                entry: entry,
                                accent: intent.color,
                                detail: detail(for: entry, in: section),
                                isHighlighted: highlighted == entry.path,
                                isLast: catalog.selectedEntry?.path == entry.path,
                                onHover: { highlighted = entry.path },
                                onLaunch: { launch(entry.path) }
                            )
                            .id(rowID(entry, section))
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: entry.path)])
                                }
                                if catalog.pinned.contains(where: { RepoEntry(path: $0).path == entry.path }) {
                                    Button("Forget this folder") {
                                        catalog.unpin(entry.path)
                                        catalog.save()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: 360)
            .onChange(of: highlighted) { _, path in
                guard scrollToHighlight else { return }
                scrollToHighlight = false
                guard let path, let section = sections.first(where: { $0.entries.contains { $0.path == path } }),
                      let entry = section.entries.first(where: { $0.path == path }) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(rowID(entry, section), anchor: nil)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            FooterButton(icon: "house", label: "Home") { launch(home.path) }
                .help("Run in your home folder, as before")
            FooterButton(icon: "folder.badge.plus", label: "Other Folder…") { chooseFolder() }
                .help("Pick any folder; it is remembered under Chosen folders")
            Menu {
                Section("Scan roots") {
                    ForEach(catalog.roots, id: \.self) { root in
                        Button("Remove \(root)") {
                            catalog.removeRoot(root)
                            catalog.save()
                            repos = catalog.scanRepos()
                        }
                        .disabled(catalog.roots.count <= 1)
                    }
                }
                Button("Add Scan Root…") { addScanRoot() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Scan roots: \(catalog.roots.joined(separator: ", "))")
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                KeyHint(keys: ["↑", "↓"], label: "move")
                KeyHint(keys: ["↩"], label: "launch")
                KeyHint(keys: ["esc"], label: "cancel")
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, -2)
        .padding(.bottom, 10)
    }

    private func emptyState(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private func rowID(_ entry: RepoEntry, _ section: RowGroup) -> String {
        "\(section.id)|\(entry.path)"
    }

    private func detail(for entry: RepoEntry, in section: RowGroup) -> String? {
        guard section.title == "Recent" || searching else { return nil }
        guard let date = catalog.lastLaunchDate(for: entry.path) else {
            return section.title == "Recent" ? "recent session" : nil
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    private func move(_ delta: Int) {
        let rows = ordered
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.path == highlighted } ?? -1
        let next = min(max(current + delta, 0), rows.count - 1)
        scrollToHighlight = true
        highlighted = rows[next].path
    }

    private func launchHighlighted() {
        if let highlighted, ordered.contains(where: { $0.path == highlighted }) {
            launch(highlighted)
        } else if let first = ordered.first {
            launch(first.path)
        }
    }

    private func launch(_ path: String) {
        onLaunch(path)
    }

    private func folderPanel(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let firstRoot = catalog.roots.first {
            panel.directoryURL = URL(fileURLWithPath: RepoEntry(path: firstRoot).path)
        }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseFolder() {
        // The popover closes when the panel takes focus; cancel first and let
        // the launch callback carry the result.
        let launchIn = onLaunch
        onCancel()
        DispatchQueue.main.async {
            guard let url = folderPanel(title: "Run Claude Code in…", prompt: "Launch Here") else { return }
            catalog.pin(url.path)
            catalog.save()
            launchIn(RepoEntry(path: url.path).path)
        }
    }

    private func addScanRoot() {
        onCancel()
        DispatchQueue.main.async {
            guard let url = folderPanel(title: "Folder that holds your repositories", prompt: "Add Root") else { return }
            catalog.addRoot(url.path)
            catalog.save()
        }
    }
}

// MARK: - Row

struct LaunchFolderRow: View {
    let entry: RepoEntry
    let accent: Color
    let detail: String?
    let isHighlighted: Bool
    let isLast: Bool
    let onHover: () -> Void
    let onLaunch: () -> Void

    var body: some View {
        Button(action: onLaunch) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isHighlighted ? accent.opacity(0.22) : Color.primary.opacity(0.07))
                        .frame(width: 28, height: 28)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(isHighlighted ? accent : .secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        if isLast {
                            Text("last used")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(accent.opacity(0.14)))
                        }
                    }
                    Text(entry.parent.abbreviatingTilde)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if isHighlighted {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                } else if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isHighlighted ? accent.opacity(0.10) : .clear)
            )
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
    }
}

// MARK: - Footer bits

private struct FooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(label).font(.system(size: 11.5, weight: .medium))
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(isHovering ? 0.12 : 0.07))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            }
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }
}

private extension String {
    var abbreviatingTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
