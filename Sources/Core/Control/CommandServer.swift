import Foundation
import Darwin

/// Local control surface: a Unix-domain socket the `claudedeck` CLI talks to.
///
/// The app owns three things the per-session scripts used to guess at:
/// 1. **Who is asking.** The connecting process's pid (LOCAL_PEERPID) is walked
///    up to the nearest live Claude Code process in the registry. That, not an
///    env var the caller could unset, is the caller's session.
/// 2. **Which terminal.** The target session's registry pid → controlling tty.
/// 3. **Whether it may.** `InjectionPolicy` (self: yes; human shell: yes;
///    peer: orchestrator role + live owner grant, consumed on use).
///
/// The typing itself stays with the proven scripts: `self-console.sh --tty`
/// (waits for the session's idle status before each line) and `launch-session.sh` (env scrub,
/// lane name, locked-console fallback). Named verbs only. ClaudeDeck never
/// registers bridge identities: a spawned lane session announces itself.
package final class CommandServer: @unchecked Sendable {
    package static let shared = CommandServer()

    package struct Paths {
        package var socket = ControlProtocol.socketPath
        package var sessionsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        package var selfConsoleScript = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/scripts/self-console.sh").path
        package var launchScript = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/scripts/launch-session.sh").path
        package var log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/claudedeck-commands.log")
        package init() {}
    }

    package var paths = Paths()
    package var policy = InjectionPolicy()
    /// How long spawn waits for the new session to appear in the registry.
    package var spawnConfirmTimeout: TimeInterval = 20
    package private(set) var isRunning = false
    package private(set) var lastError: String?

    /// Recent commands for the UI (newest first, capped).
    package struct LogEntry: Identifiable, Equatable {
        package let id = UUID()
        package let at: Date
        package let verb: String
        package let caller: String?
        package let target: String?
        package let ok: Bool
        package let message: String
    }
    private let logLock = NSLock()
    package private(set) var recent: [LogEntry] = []
    package var onLog: ((LogEntry) -> Void)?

    private var listenFD: Int32 = -1
    private var thread: Thread?

    package init() {}

    // MARK: - Lifecycle

    package func start() {
        guard !isRunning else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { lastError = "socket(): \(errnoString())"; return }

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: paths.socket).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        unlink(paths.socket)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(paths.socket.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < cap else {
            lastError = "socket path too long"; close(fd); return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
                dst[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { lastError = "bind(\(paths.socket)): \(errnoString())"; close(fd); return }
        chmod(paths.socket, 0o600)
        guard listen(fd, 8) == 0 else { lastError = "listen(): \(errnoString())"; close(fd); return }

        listenFD = fd
        isRunning = true
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "claudedeck.control"
        t.qualityOfService = .utility
        t.start()
        thread = t
    }

    package func stop() {
        guard isRunning else { return }
        isRunning = false
        close(listenFD)
        listenFD = -1
        unlink(paths.socket)
    }

    private func acceptLoop() {
        while isRunning {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if isRunning { usleep(50_000) }
                continue
            }
            autoreleasepool { serve(client) }
            close(client)
        }
    }

    // MARK: - One connection

    private func serve(_ fd: Int32) {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < ControlProtocol.maxRequestBytes {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if buffer.contains(0x0A) { break }
        }
        let line = { () -> Data in
            if let nl = buffer.firstIndex(of: 0x0A) { return Data(buffer[buffer.startIndex..<nl]) }
            return buffer
        }()

        let response: ControlResponse
        if let req = try? JSONDecoder().decode(ControlRequest.self, from: line) {
            let peerPid = Self.peerPid(of: fd)
            response = handle(req, peerPid: peerPid)
        } else {
            response = .failure("malformed request (expected one JSON object per line)")
        }
        if var out = try? JSONEncoder().encode(response) {
            out.append(0x0A)
            out.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
    }

    /// pid of the process on the other end of a Unix socket (macOS).
    package static func peerPid(of fd: Int32) -> Int? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let SOL_LOCAL_VALUE: Int32 = 0
        let LOCAL_PEERPID_VALUE: Int32 = 0x002
        guard getsockopt(fd, SOL_LOCAL_VALUE, LOCAL_PEERPID_VALUE, &pid, &len) == 0, pid > 0 else { return nil }
        return Int(pid)
    }

    // MARK: - Dispatch

    package func handle(_ req: ControlRequest, peerPid: Int?) -> ControlResponse {
        let registry = loadRegistry()
        let caller = resolveCaller(peerPid: peerPid, registry: registry)
        let response: ControlResponse

        guard let verb = req.parsedVerb else {
            response = .failure("unknown verb '\(req.verb)'. Verbs: \(ControlVerb.allCases.map(\.rawValue).joined(separator: ", "))")
            record(req, caller: caller?.id, response); return response
        }

        switch verb {
        case .ping:
            response = ControlResponse(ok: true, message: "ClaudeDeck is running",
                                       callerSession: caller?.id, appVersion: Self.appVersion)
        case .sessions:
            let infos = registry.map { s in
                ControlSessionInfo(id: s.id, name: s.displayName, cwd: s.cwd, pid: s.pid,
                                   tty: s.pid.flatMap(Self.tty(ofPid:)), status: s.status,
                                   entrypoint: s.entrypoint, isCaller: s.id == caller?.id)
            }
            response = ControlResponse(ok: true, message: "\(infos.count) live session\(infos.count == 1 ? "" : "s")",
                                       callerSession: caller?.id, sessions: infos)
        case .spawn:
            response = spawn(req, caller: caller)
        case .compact, .clear:
            response = inject(verb, req, caller: caller, registry: registry)
        }
        record(req, caller: caller?.id, response)
        return response
    }

    // MARK: Verbs

    private func spawn(_ req: ControlRequest, caller: ClaudeSession?) -> ControlResponse {
        guard let rawDir = req.dir, !rawDir.isEmpty else { return .failure("spawn needs a project directory") }
        let dir = (rawDir as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .failure("directory not found: \(dir)")
        }
        if let a = req.agent, !a.isEmpty, !ControlRequest.isValidAgentName(a) {
            return .failure("invalid agent name '\(a)' (letters, digits, . _ - up to 64)")
        }
        guard FileManager.default.isExecutableFile(atPath: paths.launchScript) else {
            return .failure("launch script missing: \(paths.launchScript)")
        }
        var args: [String] = []
        if req.background == true { args.append("--background") }
        if req.screen == true { args.append("--screen") }
        if let a = req.agent, !a.isEmpty { args += ["--agent", a] }
        if let t = req.terminal, !t.isEmpty { args += ["--terminal", t] }
        if req.dryRun == true { args.append("--dry-run") }
        args.append(dir)
        if let p = req.prompt, !p.isEmpty { args.append(p) }

        let before = Set(loadRegistry().map(\.id))
        let result = Self.run(paths.launchScript, args, timeout: 60)
        let tail = String(result.output.suffix(1500))
        guard result.status == 0 else {
            return ControlResponse(ok: false, message: "launch-session.sh exited \(result.status)",
                                   callerSession: caller?.id, output: tail)
        }
        if req.dryRun == true {
            return ControlResponse(ok: true, message: "dry run: nothing launched",
                                   callerSession: caller?.id, output: tail)
        }

        // The launcher returning 0 means the terminal accepted the command, not that
        // claude is running. Wait for a new registry entry in that directory.
        let want = Self.canonicalPath(dir)
        let deadline = Date().addingTimeInterval(spawnConfirmTimeout)
        var started: ClaudeSession?
        while true {
            started = loadRegistry().first { !before.contains($0.id) && Self.canonicalPath($0.cwd) == want }
            if started != nil || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let s = started else {
            // A detached session nobody can see may be sitting on a startup prompt; say which.
            var why = ""
            if let d = Self.detachedSession(fromLauncherOutput: result.output),
               let blocker = Self.startupBlocker(inScreen: Self.captureDetached(d)) {
                why = "; \(d.mux) session \(d.name) is stuck at \(blocker)"
            }
            return ControlResponse(ok: true,
                                   message: "launcher accepted the launch, but no new session in \(dir) appeared within \(Int(spawnConfirmTimeout))s; not confirmed running\(why)",
                                   callerSession: caller?.id, output: tail, verified: false)
        }
        let info = ControlSessionInfo(id: s.id, name: s.displayName, cwd: s.cwd, pid: s.pid,
                                      tty: s.pid.flatMap(Self.tty(ofPid:)), status: s.status,
                                      entrypoint: s.entrypoint, isCaller: false)
        return ControlResponse(ok: true, message: "session started in \(dir): \(s.displayName) (\(s.id.prefix(8)))",
                               callerSession: caller?.id, targetSession: s.id, sessions: [info],
                               output: tail, verified: true)
    }

    /// The detached multiplexer session launch-session.sh reported ("Mode: detached screen ..."
    /// and "Session: cc-..."), nil for a tab or headless launch.
    package static func detachedSession(fromLauncherOutput out: String) -> (mux: String, name: String)? {
        var mux: String?, name: String?
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Mode:"), line.contains("detached") {
                mux = line.contains("tmux") ? "tmux" : "screen"
            } else if line.hasPrefix("Session:") {
                name = line.dropFirst("Session:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let m = mux, let n = name, !n.isEmpty else { return nil }
        return (m, n)
    }

    /// Visible text of a detached session's window, empty when it cannot be read.
    package static func captureDetached(_ d: (mux: String, name: String)) -> String {
        if d.mux == "tmux" {
            return run("/usr/bin/env", ["tmux", "capture-pane", "-p", "-t", d.name], timeout: 5).output
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-hardcopy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        run("/usr/bin/env", ["screen", "-S", d.name, "-p", "0", "-X", "hardcopy", file.path], timeout: 5)
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Names the startup prompt a Claude Code screen is waiting on, nil if none recognised.
    package static func startupBlocker(inScreen text: String) -> String? {
        let t = text.lowercased()
        if t.contains("trust this folder") || t.contains("do you trust the files") {
            return "the workspace trust prompt (folder not trusted in ~/.claude.json)"
        }
        if t.contains("bypass permissions mode") && t.contains("accept") {
            return "the bypass-permissions confirmation"
        }
        if t.contains("select login method") || t.contains("paste code here") {
            return "the login prompt (not signed in)"
        }
        return nil
    }

    /// The kernel's path for a directory (F_GETPATH): absolute, symlink-resolved and in
    /// on-disk case, so `~/GitHub/x`, `/Users/me/Github/x/` and a symlinked checkout all
    /// compare equal to the getcwd() cwd Claude Code records. Falls back to a lexical
    /// symlink resolve when the path cannot be opened.
    package static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let fd = open(expanded, O_RDONLY)
        if fd >= 0 {
            defer { close(fd) }
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &buf) != -1 { return String(cString: buf) }
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func inject(_ verb: ControlVerb, _ req: ControlRequest, caller: ClaudeSession?,
                        registry: [ClaudeSession]) -> ControlResponse {
        // Resolve the target: explicit --session, else the caller itself.
        let targetId: String
        if let t = req.targetSession, !t.isEmpty {
            targetId = t
        } else if let c = caller {
            targetId = c.id
        } else {
            return .failure("no target: not inside a Claude Code session and no --session given")
        }
        guard let target = registry.first(where: { $0.id == targetId || $0.id.hasPrefix(targetId) }) else {
            return .failure("session \(targetId) is not in the live registry")
        }
        guard let pid = target.pid, Self.processIsAlive(pid) else {
            return .failure("session \(target.id) has no live process")
        }
        guard let tty = Self.tty(ofPid: pid) else {
            return .failure("session \(target.id) has no controlling terminal (headless / desktop); nothing to type into")
        }
        guard FileManager.default.isExecutableFile(atPath: paths.selfConsoleScript) else {
            return .failure("self-console script missing: \(paths.selfConsoleScript)")
        }

        let decision = policy.evaluate(callerSession: caller?.id, targetSession: target.id, targetTTY: tty)
        if case .deny(let why) = decision {
            return ControlResponse(ok: false, message: "BLOCKED: \(why)", callerSession: caller?.id,
                                   targetSession: target.id, targetTTY: tty)
        }
        // A custom wake line is free text typed into the target terminal. On your
        // own session that is yours to decide; on a peer it would turn a grant
        // for "/compact" into a channel for arbitrary input. Peer compacts get
        // the engine's default wake line or none.
        if case .allowPeer = decision, let w = req.wake, !w.isEmpty {
            return ControlResponse(ok: false,
                message: "BLOCKED: --wake is not allowed on a peer session (free text would be typed into another agent's terminal). Use --no-wake or the default wake line.",
                callerSession: caller?.id, targetSession: target.id, targetTTY: tty)
        }

        var args = ["--tty", tty]
        let command: String
        switch verb {
        case .compact:
            command = "/compact"
            if req.noWake == true { args.append("--no-wake") }
            args.append(command)
            if let w = req.wake, !w.isEmpty { args.append(w) }
        case .clear:
            command = "/clear"
            args += ["--no-wake", command]
        default:
            return .failure("not an injectable verb")
        }

        let result = Self.run(paths.selfConsoleScript, args, timeout: 30)
        if case .allowPeer = decision {
            policy.consumePeerGrant(targetTTY: tty, commandHead: "claudedeck \(verb.rawValue) --session \(target.id)")
        }
        let how: String = {
            switch decision {
            case .allowSelf:  return "self"
            case .allowHuman: return "owner shell"
            case .allowPeer:  return "peer (grant consumed)"
            case .deny:       return "denied"
            }
        }()
        return ControlResponse(
            ok: result.status == 0,
            message: result.status == 0
                ? "\(command) scheduled on \(target.displayName) [\(tty)] (\(how)); it lands when the session is idle"
                : "self-console.sh exited \(result.status)",
            callerSession: caller?.id, targetSession: target.id, targetTTY: tty,
            output: String(result.output.suffix(1500)))
    }

    // MARK: - Registry + process helpers

    package func loadRegistry() -> [ClaudeSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: paths.sessionsDir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let s = try? JSONDecoder().decode(ClaudeSession.self, from: data),
                  let pid = s.pid, Self.processIsAlive(pid)
            else { return nil }
            return s
        }
    }

    /// Walks the connecting process's ancestry for a live registry pid.
    package func resolveCaller(peerPid: Int?, registry: [ClaudeSession]) -> ClaudeSession? {
        guard var pid = peerPid else { return nil }
        let byPid = Dictionary(registry.compactMap { s in s.pid.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        var guardCount = 0
        while pid > 1, guardCount < 40 {
            if let s = byPid[pid] { return s }
            guard let parent = Self.parentPid(of: pid) else { return nil }
            pid = parent
            guardCount += 1
        }
        return nil
    }

    package static func processIsAlive(_ pid: Int) -> Bool { kill(pid_t(pid), 0) == 0 }

    package static func parentPid(of pid: Int) -> Int? {
        let out = run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"], timeout: 5).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(out)
    }

    /// `/dev/ttysNNN` for a pid, nil when it has no controlling terminal.
    package static func tty(ofPid pid: Int) -> String? {
        let out = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"], timeout: 5).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out != "??", out != "?" else { return nil }
        return "/dev/" + out
    }

    package static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    @discardableResult
    package static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        // Scrub inherited Claude markers so a spawned session never thinks it is a child.
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDE") { env.removeValue(forKey: k) }
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "cannot run \(path): \(error.localizedDescription)") }
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Audit

    /// Extra fields for the log line. spawn records how it was launched, never the prompt text.
    package static func auditDetail(_ req: ControlRequest) -> String {
        guard req.parsedVerb == .spawn else { return "" }
        let mode = req.background == true ? "background" : req.screen == true ? "screen" : "tab"
        var d = " dir=\(req.dir ?? "-") agent=\(req.agent ?? "-") mode=\(mode)"
        if let t = req.terminal { d += " terminal=\(t)" }
        d += " prompt=\((req.prompt ?? "").isEmpty ? "no" : "yes")"
        if req.dryRun == true { d += " dry-run" }
        return d
    }

    private func record(_ req: ControlRequest, caller: String?, _ res: ControlResponse) {
        let entry = LogEntry(at: Date(), verb: req.verb, caller: caller,
                             target: res.targetSession ?? req.targetSession, ok: res.ok, message: res.message)
        logLock.lock()
        recent.insert(entry, at: 0)
        if recent.count > 50 { recent.removeLast(recent.count - 50) }
        logLock.unlock()
        let line = "\(ISO8601DateFormatter().string(from: entry.at)) \(res.ok ? "ok " : "ERR") \(req.verb) caller=\(caller ?? "-") target=\(entry.target ?? "-")\(Self.auditDetail(req)) :: \(res.message)\n"
        if let h = try? FileHandle(forWritingTo: paths.log) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: paths.log)
        }
        onLog?(entry)
    }

    private func errnoString() -> String { String(cString: strerror(errno)) }
}
