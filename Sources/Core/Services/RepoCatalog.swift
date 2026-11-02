import Foundation

/// A folder the deck can start a Claude Code session in.
package struct RepoEntry: Identifiable, Hashable, Sendable {
    package let path: String
    package var id: String { path }
    package var name: String { (path as NSString).lastPathComponent }
    package var parent: String { (path as NSString).deletingLastPathComponent }
    package var abbreviated: String { (path as NSString).abbreviatingWithTildeInPath }

    package init(path: String) {
        self.path = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}

/// Where the launch buttons may start a session: git repositories found one
/// level under each configured root, folders the user chose by hand, and the
/// folders used most recently. Persisted at `~/.claude/claudedeck-repos.json`
/// so the choice survives relaunches and the CLI can read it later.
package struct RepoCatalog: Codable, Equatable, Sendable {
    /// Folders scanned for git repositories. Stored with `~` so the file is
    /// portable between machines.
    package var roots: [String]
    /// Folders chosen through the open panel. Shown even when they are not
    /// under a root and not git repositories.
    package var pinned: [String]
    /// Folders launched from the GUI, most recent first.
    package var recent: [String]
    /// The folder the launch buttons currently target. `nil` = home.
    package var selected: String?
    /// When each folder was last launched from the GUI, by normalized path.
    package var lastLaunched: [String: Double]

    package static let defaultRoots = ["~/GitHub"]
    package static let recentLimit = 8

    package static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/claudedeck-repos.json")
    }

    package init(roots: [String] = RepoCatalog.defaultRoots,
                 pinned: [String] = [],
                 recent: [String] = [],
                 selected: String? = nil,
                 lastLaunched: [String: Double] = [:]) {
        self.roots = roots
        self.pinned = pinned
        self.recent = recent
        self.selected = selected
        self.lastLaunched = lastLaunched
    }

    // Older files lack `lastLaunched`; every field decodes with a default so
    // a hand-edited or partial file still loads.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? RepoCatalog.defaultRoots
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        recent = try c.decodeIfPresent([String].self, forKey: .recent) ?? []
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        lastLaunched = try c.decodeIfPresent([String: Double].self, forKey: .lastLaunched) ?? [:]
    }

    // MARK: - Persistence

    package static func load(from url: URL = RepoCatalog.defaultPath) -> RepoCatalog {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RepoCatalog.self, from: data) else {
            return RepoCatalog()
        }
        var catalog = decoded
        if catalog.roots.isEmpty { catalog.roots = RepoCatalog.defaultRoots }
        return catalog
    }

    package func save(to url: URL = RepoCatalog.defaultPath) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Mutation

    /// Make `path` the launch target and move it to the head of the recent list.
    package mutating func noteLaunch(in path: String, at date: Date = Date()) {
        let entry = RepoEntry(path: path)
        selected = entry.path
        recent.removeAll { RepoEntry(path: $0).path == entry.path }
        recent.insert(entry.path, at: 0)
        if recent.count > RepoCatalog.recentLimit {
            for dropped in recent[RepoCatalog.recentLimit...] { lastLaunched[dropped] = nil }
            recent.removeLast(recent.count - RepoCatalog.recentLimit)
        }
        lastLaunched[entry.path] = date.timeIntervalSince1970
    }

    package func lastLaunchDate(for path: String) -> Date? {
        lastLaunched[RepoEntry(path: path).path].map(Date.init(timeIntervalSince1970:))
    }

    /// Remember a folder chosen by hand so it stays in the list.
    package mutating func pin(_ path: String) {
        let entry = RepoEntry(path: path)
        guard !pinned.contains(where: { RepoEntry(path: $0).path == entry.path }) else { return }
        pinned.append(entry.path)
    }

    package mutating func unpin(_ path: String) {
        let target = RepoEntry(path: path).path
        pinned.removeAll { RepoEntry(path: $0).path == target }
    }

    package mutating func addRoot(_ path: String) {
        let abbreviated = (RepoEntry(path: path).path as NSString).abbreviatingWithTildeInPath
        guard !roots.contains(where: { RepoEntry(path: $0).path == RepoEntry(path: abbreviated).path }) else { return }
        roots.append(abbreviated)
    }

    package mutating func removeRoot(_ path: String) {
        let target = RepoEntry(path: path).path
        roots.removeAll { RepoEntry(path: $0).path == target }
    }

    // MARK: - Resolution

    /// The folder a launch should use right now: the selection when it still
    /// exists on disk, otherwise home.
    package func effectiveDirectory(fileManager: FileManager = .default) -> String {
        if let selected, RepoCatalog.isDirectory(RepoEntry(path: selected).path, fileManager: fileManager) {
            return RepoEntry(path: selected).path
        }
        return NSHomeDirectory()
    }

    package var selectedEntry: RepoEntry? { selected.map(RepoEntry.init(path:)) }

    package func pinnedEntries(fileManager: FileManager = .default) -> [RepoEntry] {
        pinned.map(RepoEntry.init(path:))
            .filter { RepoCatalog.isDirectory($0.path, fileManager: fileManager) }
    }

    package func recentEntries(fileManager: FileManager = .default) -> [RepoEntry] {
        recent.map(RepoEntry.init(path:))
            .filter { RepoCatalog.isDirectory($0.path, fileManager: fileManager) }
    }

    package func scanRepos(fileManager: FileManager = .default) -> [RepoEntry] {
        RepoCatalog.scan(roots: roots, fileManager: fileManager)
    }

    // MARK: - Scanning

    /// Immediate children of each root that are git repositories: a `.git`
    /// directory, or a `.git` file (linked worktrees). Hidden folders are
    /// skipped. Sorted by name, case-insensitive, duplicates removed.
    package static func scan(roots: [String], fileManager: FileManager = .default) -> [RepoEntry] {
        var seen = Set<String>()
        var found: [RepoEntry] = []
        for root in roots {
            let rootPath = RepoEntry(path: root).path
            guard let children = try? fileManager.contentsOfDirectory(atPath: rootPath) else { continue }
            for child in children where !child.hasPrefix(".") {
                let path = (rootPath as NSString).appendingPathComponent(child)
                guard isDirectory(path, fileManager: fileManager) else { continue }
                let gitMarker = (path as NSString).appendingPathComponent(".git")
                guard fileManager.fileExists(atPath: gitMarker) else { continue }
                let entry = RepoEntry(path: path)
                if seen.insert(entry.path).inserted { found.append(entry) }
            }
        }
        return found.sorted {
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            return byName == .orderedSame ? $0.path < $1.path : byName == .orderedAscending
        }
    }

    package static func isDirectory(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Search

    /// Case-insensitive match on the folder name. Prefix matches rank first,
    /// then substring matches, then names that contain the query's characters
    /// in order (so "cpb" finds "cheqpass-backend"). Ties keep input order.
    package static func filter(_ entries: [RepoEntry], query: String) -> [RepoEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        var ranked: [(rank: Int, index: Int, entry: RepoEntry)] = []
        for (index, entry) in entries.enumerated() {
            let name = entry.name.lowercased()
            if name.hasPrefix(needle) {
                ranked.append((0, index, entry))
            } else if name.contains(needle) {
                ranked.append((1, index, entry))
            } else if isSubsequence(needle, of: name) {
                ranked.append((2, index, entry))
            } else if entry.abbreviated.lowercased().contains(needle) {
                ranked.append((3, index, entry))
            }
        }
        return ranked
            .sorted { $0.rank == $1.rank ? $0.index < $1.index : $0.rank < $1.rank }
            .map(\.entry)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var cursor = haystack.startIndex
        for ch in needle {
            guard let next = haystack[cursor...].firstIndex(of: ch) else { return false }
            cursor = haystack.index(after: next)
        }
        return true
    }

    // MARK: - Claude Code project keys

    /// Claude Code keeps a project's transcripts under `~/.claude/projects/`
    /// in a folder named after the cwd with every character that is not a
    /// letter or digit replaced by `-`. The mapping is lossy, so a key cannot
    /// be turned back into a path; match known folders against it instead.
    package static func projectKey(forPath path: String) -> String {
        String(RepoEntry(path: path).path.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
    }

    /// The folder a Claude Code project key most likely stands for, drawn
    /// from every folder the deck knows about: `extra` exact paths first (for
    /// example live session cwds), then recent, pinned and scanned folders,
    /// then home. `nil` when nothing matches.
    package func resolveDirectory(projectKey key: String,
                                  extra: [String] = [],
                                  fileManager: FileManager = .default) -> String? {
        let candidates = extra.map(RepoEntry.init(path:))
            + recentEntries(fileManager: fileManager)
            + pinnedEntries(fileManager: fileManager)
            + scanRepos(fileManager: fileManager)
            + [RepoEntry(path: NSHomeDirectory())]
        return RepoCatalog.matchRecent(projectKeys: [key], candidates: candidates).first?.path
    }

    /// Known folders whose project key matches one of `projectKeys`, in the
    /// order the keys were given (most recent first), without duplicates.
    package static func matchRecent(projectKeys: [String], candidates: [RepoEntry]) -> [RepoEntry] {
        var byKey: [String: RepoEntry] = [:]
        for candidate in candidates {
            byKey[projectKey(forPath: candidate.path)] = candidate
        }
        var seen = Set<String>()
        var matched: [RepoEntry] = []
        for key in projectKeys {
            guard let entry = byKey[key], seen.insert(entry.path).inserted else { continue }
            matched.append(entry)
        }
        return matched
    }
}
