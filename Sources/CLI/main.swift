import Foundation
import Darwin
import ClaudeDeckCore

// claudedeck — command-line client for the ClaudeDeck control socket.
//
//   claudedeck ping
//   claudedeck sessions
//   claudedeck spawn ~/GitHub/repo [--agent lane-a] [--prompt "start on X"] [--dry-run]
//     exit 0 = new session confirmed in the registry, 2 = launched but not confirmed
//   claudedeck compact [--session ID] [--wake TEXT | --no-wake]
//   claudedeck clear   [--session ID]
//   claudedeck statusline [--then CMD] | --install [--replace] | --uninstall | --status
//
// When the app is not running: spawn and self-targeted compact/clear fall
// back to the scripts directly; peer targeting refuses (the app is the only
// place the owner-grant policy is enforced outside the Bash hook).

let argv = Array(CommandLine.arguments.dropFirst())
if argv.isEmpty || argv == ["-h"] || argv == ["--help"] || argv == ["help"] {
    print(ControlCLIArgs.usage)
    print("  usage     token history from the ledger: usage [--days N] [--json] (reads ~/.claude/claudedeck-ledger.json, no app needed)")
    print("  statusline  Claude Code status line: statusline [--then CMD] (reads stdin, feeds the live usage bars)")
    print("            statusline --install [--replace] | --uninstall | --status  (edits ~/.claude/settings.json, with a backup)")
    exit(argv.isEmpty ? 2 : 0)
}

// `statusline` is run by Claude Code itself after each message; it never touches the socket.
if argv.first == "statusline" {
    var then: String? = nil
    var action = "render"
    var replace = false
    var it = argv.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--then":
            guard let c = it.next() else { fputs("claudedeck: --then needs a command\n", stderr); exit(2) }
            then = c
        case "--install": action = "install"
        case "--uninstall": action = "uninstall"
        case "--status": action = "status"
        case "--replace": replace = true
        default: fputs("claudedeck: unexpected argument '\(a)'\n", stderr); exit(2)
        }
    }

    func describe(_ state: StatusLineSetup.State) -> String {
        switch state {
        case .notSet: return "not set (Claude Code shows its default; usage bars use the estimate)"
        case .installed(nil): return "ClaudeDeck status line"
        case .installed(let then?): return "ClaudeDeck status line, chained to: \(then)"
        case .other(let cmd): return "another command, not ClaudeDeck: \(cmd) (usage bars use the estimate unless it writes ~/.claude/claudedeck-usage.json)"
        case .unrecognised: return "a statusLine entry without a command"
        }
    }

    switch action {
    case "status":
        print("statusLine: \(describe(StatusLineSetup.currentState()))")
        if let w = UsageWindows.load() {
            let mins = Int(w.age() / 60)
            print("live usage: written \(mins)m ago" + (w.sevenDay.map { ", weekly \($0.current().usedPercentage)%" } ?? ""))
        } else {
            print("live usage: none yet (~/.claude/claudedeck-usage.json is written on the next status line refresh)")
        }
        exit(0)
    case "install", "uninstall":
        let cli = StatusLineSetup.defaultCLIPath
        do {
            let result = try StatusLineSetup.apply { text in
                action == "install"
                    ? try StatusLineSetup.install(text, cli: cli, replace: replace)
                    : try StatusLineSetup.uninstall(text)
            }
            switch result.change {
            case .unchanged: print("Status line: already ClaudeDeck, nothing changed")
            case .installed: print("Status line: set to ClaudeDeck")
            case .wrapped(let prev): print("Status line: ClaudeDeck, still showing your own line (\(prev))")
            case .replaced(let prev): print("Status line: set to ClaudeDeck, replacing \(prev)")
            case .restored(let cmd): print("Status line: restored to \(cmd)")
            case .removed: print("Status line: removed")
            }
            if let b = result.backup { print("Backup:      \(b.path)") }
            exit(0)
        } catch {
            fputs("claudedeck: \(error)\n", stderr)
            exit(1)
        }
    default:
        let input = FileHandle.standardInput.readDataToEndOfFile()
        StatusLine.saveUsage(input)
        if let then {
            // The user's own status line keeps the display; ClaudeDeck only saved the usage.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", then]
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            if (try? p.run()) != nil {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0, !out.isEmpty {
                    FileHandle.standardOutput.write(out)
                    exit(0)
                }
            }
        }
        print(StatusLine.render(input))
        exit(0)
    }
}

// `usage` is a local read of the ledger; it never touches the socket.
if argv.first == "usage" {
    var days = 30
    var asJSON = false
    var it = argv.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--days": days = it.next().flatMap(Int.init) ?? days
        case "--json": asJSON = true
        default: fputs("claudedeck: unexpected argument '\(a)'\n", stderr); exit(2)
        }
    }
    let ledger = UsageLedger.shared
    func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }
    let window = ledger.totals(lastDays: days)
    if asJSON {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Out: Codable { let days: Int; let byModel: [String: LedgerTotals]; let monthly: [String: [String: LedgerTotals]]; let cleanupPeriodDays: Int; let firstDay: String? }
        let monthly = Dictionary(uniqueKeysWithValues: ledger.monthly().map { ($0.month, $0.byModel) })
        let out = Out(days: days, byModel: window, monthly: monthly,
                      cleanupPeriodDays: UsageLedger.cleanupPeriodDays(), firstDay: ledger.firstDay)
        if let d = try? enc.encode(out) { print(String(decoding: d, as: UTF8.self)) }
        exit(0)
    }
    print("Claude Code keeps transcripts \(UsageLedger.cleanupPeriodDays()) days; ledger has \(ledger.dayCount) days" + (ledger.firstDay.map { " since \($0)" } ?? ""))
    func row(_ label: String, _ t: LedgerTotals) {
        print(String(format: "  %-22@ %9@ tokens  %8@ out  %7@ think  $%8.2f  %4d sessions",
                     label as NSString, fmt(t.allTokens) as NSString, fmt(t.output) as NSString,
                     fmt(t.thinking) as NSString, t.cost, t.sessions))
    }
    print("Last \(days) days:")
    row("all models", ledger.grand(window))
    for (model, t) in window.sorted(by: { $0.value.cost > $1.value.cost }) {
        row(ModelCatalog.shared.resolve(model).displayName, t)
    }
    let months = ledger.monthly()
    if !months.isEmpty {
        print("By month:")
        for m in months.prefix(12) { row(m.month, ledger.grand(m.byModel)) }
    }
    exit(0)
}

let parsed: ControlCLIArgs.Parsed
do {
    parsed = try ControlCLIArgs.parse(argv)
} catch {
    fputs("claudedeck: \(error)\n\n\(ControlCLIArgs.usage)", stderr)
    exit(2)
}

func sendToApp(_ req: ControlRequest) -> ControlResponse? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(ControlProtocol.socketPath.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.count < cap else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
            for (i, b) in path.enumerated() { dst[i] = b }
            dst[path.count] = 0
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else { return nil }

    guard var payload = try? JSONEncoder().encode(req) else { return nil }
    payload.append(0x0A)
    let sent = payload.withUnsafeBytes { raw -> Bool in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    guard sent else { return nil }

    var tv = timeval(tv_sec: 90, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(chunk, count: n)
        if buffer.contains(0x0A) { break }
    }
    let line = { () -> Data in
            if let nl = buffer.firstIndex(of: 0x0A) { return Data(buffer[buffer.startIndex..<nl]) }
            return buffer
        }()
    return try? JSONDecoder().decode(ControlResponse.self, from: line)
}

func execScript(_ path: String, _ args: [String]) -> Never {
    guard FileManager.default.isExecutableFile(atPath: path) else {
        fputs("claudedeck: script not found or not executable: \(path)\n", stderr)
        exit(127)
    }
    // Replace this process with the script so its stdio and lifetime are the caller's.
    let cargs: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    execv(path, cargs)
    fputs("claudedeck: exec failed for \(path): \(String(cString: strerror(errno)))\n", stderr)
    exit(127)
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let req = parsed.request

if let res = sendToApp(req) {
    if parsed.json, let data = try? JSONEncoder().encode(res) {
        print(String(decoding: data, as: UTF8.self))
    } else {
        print((res.ok ? "" : "claudedeck: ") + res.message)
        if let sessions = res.sessions {
            for s in sessions {
                let mark = s.isCaller ? "*" : " "
                let pid = s.pid.map(String.init) ?? "-"
                print("\(mark) \(s.id.prefix(8))  \(s.status ?? "-")\t\(s.tty ?? "no tty")\tpid \(pid)\t\(s.name)  (\(s.cwd))")
            }
        }
        if let out = res.output, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    // 2 = the launcher succeeded but the new session never showed up: not confirmed running.
    exit(!res.ok ? 1 : res.verified == false ? 2 : 0)
}

// ---- App not running: fallbacks ----
switch req.parsedVerb {
case .ping:
    fputs("claudedeck: ClaudeDeck is not running (no socket at \(ControlProtocol.socketPath))\n", stderr)
    exit(1)
case .sessions:
    fputs("claudedeck: ClaudeDeck is not running; open /Applications/ClaudeDeck.app for session listing\n", stderr)
    exit(1)
case .spawn:
    var args: [String] = []
    if req.background == true { args.append("--background") }
    if req.screen == true { args.append("--screen") }
    if let a = req.agent { args += ["--agent", a] }
    if let t = req.terminal { args += ["--terminal", t] }
    if req.dryRun == true { args.append("--dry-run") }
    guard let dir = req.dir else {
        fputs("claudedeck: spawn needs a project directory\n", stderr)
        exit(64)
    }
    args.append(dir)
    if let p = req.prompt { args.append(p) }
    fputs("claudedeck: app not running, launching directly via launch-session.sh\n", stderr)
    execScript("\(home)/.claude/scripts/launch-session.sh", args)
case .compact, .clear:
    if let t = req.targetSession, !t.isEmpty {
        fputs("claudedeck: ClaudeDeck is not running. Acting on another session (--session) is only allowed through the app, which enforces the owner-grant policy. Open /Applications/ClaudeDeck.app, or surface to the owner.\n", stderr)
        exit(1)
    }
    var args: [String] = []
    if req.parsedVerb == .clear || req.noWake == true { args.append("--no-wake") }
    args.append(req.parsedVerb == .clear ? "/clear" : "/compact")
    if req.parsedVerb == .compact, let w = req.wake, !w.isEmpty { args.append(w) }
    fputs("claudedeck: app not running, using self-console.sh on this session\n", stderr)
    execScript("\(home)/.claude/scripts/self-console.sh", args)
case .none:
    exit(2)
}
