import ClaudeDeckCore
import Foundation

func runRepoCatalogTests() {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory
        .appendingPathComponent("claudedeck-repocatalog-\(UUID().uuidString)")
    let root = sandbox.appendingPathComponent("GitHub")
    defer { try? fm.removeItem(at: sandbox) }

    func mkdir(_ path: String) { try? fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
    func touch(_ path: String) { fm.createFile(atPath: path, contents: Data()) }

    // Fixture: two repos, one worktree (.git file), one plain folder, one
    // hidden repo, one loose file.
    mkdir(root.appendingPathComponent("zeta/.git").path)
    mkdir(root.appendingPathComponent("Alpha/.git").path)
    mkdir(root.appendingPathComponent("worktree").path)
    touch(root.appendingPathComponent("worktree/.git").path)
    mkdir(root.appendingPathComponent("notes").path)
    mkdir(root.appendingPathComponent(".hidden/.git").path)
    touch(root.appendingPathComponent("stray.txt").path)

    suite("RepoCatalog — scan") {
        let repos = RepoCatalog.scan(roots: [root.path])
        expectEqual(repos.map(\.name), ["Alpha", "worktree", "zeta"],
                    "git dirs and worktree files found, sorted case-insensitively")
        expect(!repos.contains { $0.name == "notes" }, "plain folder without .git skipped")
        expect(!repos.contains { $0.name == ".hidden" }, "hidden folder skipped")

        let twice = RepoCatalog.scan(roots: [root.path, root.path])
        expectEqual(twice.count, 3, "same root listed twice does not duplicate repos")

        let missing = RepoCatalog.scan(roots: [sandbox.appendingPathComponent("nope").path])
        expect(missing.isEmpty, "missing root yields no repos and no crash")
    }

    suite("RepoCatalog — filter") {
        let entries = ["cheqpass-backend", "cheqpass-mobile", "claude-deck", "agentfreeway-v2", "archmap"]
            .map { RepoEntry(path: "/r/\($0)") }
        expectEqual(RepoCatalog.filter(entries, query: "").map(\.name), entries.map(\.name),
                    "empty query returns everything in order")
        expectEqual(RepoCatalog.filter(entries, query: "CL").first?.name, "claude-deck",
                    "prefix match is case-insensitive and ranks first")
        expectEqual(RepoCatalog.filter(entries, query: "deck").map(\.name), ["claude-deck"],
                    "substring match excludes non-matching names")
        expectEqual(RepoCatalog.filter(entries, query: "pass").map(\.name),
                    ["cheqpass-backend", "cheqpass-mobile"], "substring match keeps input order")
        expectEqual(RepoCatalog.filter(entries, query: "cpb").first?.name, "cheqpass-backend",
                    "subsequence match finds cheqpass-backend from cpb")
        expectEqual(RepoCatalog.filter(entries, query: "cqm").map(\.name), ["cheqpass-mobile"],
                    "subsequence match: non-subsequence names excluded")
        expectEqual(RepoCatalog.filter(entries, query: "a").first?.name, "agentfreeway-v2",
                    "prefix matches rank above substring matches")
        expect(RepoCatalog.filter(entries, query: "zzz").isEmpty, "no match = empty")
    }

    suite("RepoCatalog — recent, pinned, selection") {
        var catalog = RepoCatalog(roots: [root.path])
        expectEqual(catalog.effectiveDirectory(), NSHomeDirectory(), "no selection = home")

        let alpha = root.appendingPathComponent("Alpha").path
        let zeta  = root.appendingPathComponent("zeta").path
        catalog.noteLaunch(in: alpha)
        catalog.noteLaunch(in: zeta)
        catalog.noteLaunch(in: alpha)
        expectEqual(catalog.recent, [alpha, zeta], "recent is most-recent-first with no duplicates")
        expectEqual(catalog.selected, alpha, "last launch becomes the selection")
        expectEqual(catalog.effectiveDirectory(), alpha, "existing selection is used")

        catalog.selected = sandbox.appendingPathComponent("gone").path
        expectEqual(catalog.effectiveDirectory(), NSHomeDirectory(), "missing selection falls back to home")

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        catalog.noteLaunch(in: zeta, at: when)
        expectEqual(catalog.lastLaunchDate(for: zeta + "/"), when, "launch time recorded per normalized path")
        expectNil(catalog.lastLaunchDate(for: root.appendingPathComponent("never").path), "unlaunched folder has no date")

        for i in 0..<(RepoCatalog.recentLimit + 3) {
            catalog.noteLaunch(in: root.appendingPathComponent("r\(i)").path)
        }
        expectEqual(catalog.recent.count, RepoCatalog.recentLimit, "recent list is capped")
        expectEqual(catalog.lastLaunched.count, RepoCatalog.recentLimit, "dropped folders lose their launch time")
        expectNil(catalog.lastLaunchDate(for: zeta), "folder pushed out of recent loses its date")

        catalog.pin(alpha)
        catalog.pin(alpha + "/")
        expectEqual(catalog.pinned, [alpha], "pin normalizes and deduplicates")
        catalog.unpin(alpha)
        expect(catalog.pinned.isEmpty, "unpin removes the entry")

        catalog.addRoot(root.path)
        expectEqual(catalog.roots.count, 1, "adding an existing root is a no-op")
        catalog.addRoot(sandbox.path)
        expectEqual(catalog.roots.count, 2, "new root appended")
        catalog.removeRoot(sandbox.path)
        expectEqual(catalog.roots.count, 1, "root removed")

        let stale = RepoCatalog(recent: [alpha, sandbox.appendingPathComponent("gone").path])
        expectEqual(stale.recentEntries().map(\.path), [alpha], "recent entries drop folders that no longer exist")
    }

    suite("RepoCatalog — persistence") {
        let file = sandbox.appendingPathComponent("cfg/claudedeck-repos.json")
        var catalog = RepoCatalog(roots: ["~/GitHub", root.path])
        catalog.noteLaunch(in: root.appendingPathComponent("zeta").path)
        catalog.pin(root.appendingPathComponent("notes").path)
        catalog.save(to: file)
        expect(fm.fileExists(atPath: file.path), "save creates the file and its folder")

        let loaded = RepoCatalog.load(from: file)
        expectEqual(loaded, catalog, "round-trips through JSON")

        let fresh = RepoCatalog.load(from: sandbox.appendingPathComponent("absent.json"))
        expectEqual(fresh.roots, RepoCatalog.defaultRoots, "missing file = defaults")
        expectNil(fresh.selected, "missing file = no selection")

        try? Data("{\"roots\":[],\"pinned\":[],\"recent\":[]}".utf8).write(to: file)
        expectEqual(RepoCatalog.load(from: file).roots, RepoCatalog.defaultRoots,
                    "empty roots in file are replaced with the defaults")

        try? Data("{\"roots\":[\"~/GitHub\"],\"recent\":[\"/a\"]}".utf8).write(to: file)
        let partial = RepoCatalog.load(from: file)
        expectEqual(partial.recent, ["/a"], "file without lastLaunched still loads")
        expect(partial.lastLaunched.isEmpty, "missing lastLaunched defaults to empty")

        try? Data("not json".utf8).write(to: file)
        expectEqual(RepoCatalog.load(from: file), RepoCatalog(), "corrupt file = defaults")
    }

    suite("RepoCatalog — Claude Code project keys") {
        expectEqual(RepoCatalog.projectKey(forPath: "/Users/dustin/GitHub/claude-deck"),
                    "-Users-dustin-GitHub-claude-deck", "slashes become dashes, dashes stay")
        expectEqual(RepoCatalog.projectKey(forPath: "/Users/dustin/GitHub/_ads.ref x"),
                    "-Users-dustin-GitHub--ads-ref-x", "underscore, dot and space become dashes")

        let candidates = ["/p/alpha", "/p/beta", "/p/gamma"].map(RepoEntry.init(path:))
        let keys = ["-p-gamma", "-p-unknown", "-p-alpha", "-p-gamma"]
        expectEqual(RepoCatalog.matchRecent(projectKeys: keys, candidates: candidates).map(\.name),
                    ["gamma", "alpha"], "matches keep key order, skip unknown keys, dedupe")
    }

    suite("RepoCatalog — resolveDirectory") {
        let alpha = root.appendingPathComponent("Alpha").path
        let notes = root.appendingPathComponent("notes").path
        var catalog = RepoCatalog(roots: [root.path])
        expectEqual(catalog.resolveDirectory(projectKey: RepoCatalog.projectKey(forPath: alpha)), alpha,
                    "scanned repo resolves from its project key")
        expectNil(catalog.resolveDirectory(projectKey: RepoCatalog.projectKey(forPath: notes)),
                  "non-repo folder unknown to the catalog does not resolve")
        catalog.pin(notes)
        expectEqual(catalog.resolveDirectory(projectKey: RepoCatalog.projectKey(forPath: notes)), notes,
                    "pinned folder resolves")
        expectEqual(catalog.resolveDirectory(projectKey: RepoCatalog.projectKey(forPath: NSHomeDirectory())),
                    NSHomeDirectory(), "home resolves")
        let live = sandbox.appendingPathComponent("live-cwd").path
        expectEqual(catalog.resolveDirectory(projectKey: RepoCatalog.projectKey(forPath: live), extra: [live]), live,
                    "extra exact paths (live session cwds) resolve first")
        expectNil(catalog.resolveDirectory(projectKey: "-nowhere-at-all"), "unknown key = nil")
    }

    suite("RepoEntry — paths") {
        let entry = RepoEntry(path: "~/GitHub/claude-deck/")
        expectEqual(entry.path, NSHomeDirectory() + "/GitHub/claude-deck", "tilde expanded, trailing slash dropped")
        expectEqual(entry.name, "claude-deck", "name is the last component")
        expectEqual(entry.abbreviated, "~/GitHub/claude-deck", "abbreviated form uses tilde")
    }
}
