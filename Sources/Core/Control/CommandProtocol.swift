import Foundation

// MARK: - Wire protocol between the `claudedeck` CLI and the app
//
// Transport: a Unix domain socket at `ControlProtocol.socketPath`, mode 0600.
// One request per connection: a single JSON object terminated by "\n",
// answered by a single JSON object terminated by "\n". Named verbs only —
// the app never accepts arbitrary text to type into a terminal.

package enum ControlProtocol {
    package static let version = 1
    package static let socketPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedeck.sock").path
    package static let maxRequestBytes = 64 * 1024
}

package enum ControlVerb: String, Codable, CaseIterable {
    /// Liveness + version.
    case ping
    /// List registry sessions with their tty and status.
    case sessions
    /// Start a new Claude Code session via launch-session.sh.
    case spawn
    /// Type /compact into a session (self by default).
    case compact
    /// Type /clear into a session (self by default).
    case clear

    package var summary: String {
        switch self {
        case .ping:     return "check that ClaudeDeck is running"
        case .sessions: return "list live Claude Code sessions"
        case .spawn:    return "spawn a new Claude Code session: spawn <dir> [--agent NAME] [--prompt TEXT] [--screen|--background] [--terminal NAME] [--dry-run]"
        case .compact:  return "compact a session's context: compact [--session ID] [--wake TEXT | --no-wake]"
        case .clear:    return "clear a session's context: clear [--session ID]"
        }
    }
}

package struct ControlRequest: Codable, Equatable {
    package var verb: String
    /// Target session id for compact/clear. Nil = the caller's own session.
    package var targetSession: String?
    /// Informational only. The app derives the real caller from the
    /// connecting process (LOCAL_PEERPID → ancestor claude pid → registry).
    package var callerSessionHint: String?
    package var callerPidHint: Int?

    // spawn
    package var dir: String?
    package var agent: String?
    package var prompt: String?
    package var screen: Bool?
    package var background: Bool?
    /// Forwarded to launch-session.sh --terminal (iterm|terminal on macOS).
    package var terminal: String?
    /// Forwarded to launch-session.sh --dry-run: print the decision, launch nothing.
    package var dryRun: Bool?

    // compact
    package var wake: String?
    package var noWake: Bool?

    package init(verb: String, targetSession: String? = nil,
                 callerSessionHint: String? = nil, callerPidHint: Int? = nil,
                 dir: String? = nil, agent: String? = nil, prompt: String? = nil,
                 screen: Bool? = nil, background: Bool? = nil,
                 terminal: String? = nil, dryRun: Bool? = nil,
                 wake: String? = nil, noWake: Bool? = nil) {
        self.verb = verb; self.targetSession = targetSession
        self.callerSessionHint = callerSessionHint; self.callerPidHint = callerPidHint
        self.dir = dir; self.agent = agent; self.prompt = prompt
        self.screen = screen; self.background = background
        self.terminal = terminal; self.dryRun = dryRun
        self.wake = wake; self.noWake = noWake
    }

    package var parsedVerb: ControlVerb? { ControlVerb(rawValue: verb) }

    /// Lane names are handed to the session (BRIDGE_AGENT) and name detached screen sessions;
    /// the session registers itself on the bridge. Allowed:
    /// letters, digits, `.` `_` `-`, up to 64.
    package static func isValidAgentName(_ a: String) -> Bool {
        !a.isEmpty && a.count <= 64 && a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }
}

package struct ControlSessionInfo: Codable, Equatable {
    package var id: String
    package var name: String
    package var cwd: String
    package var pid: Int?
    package var tty: String?
    package var status: String?
    package var entrypoint: String?
    package var isCaller: Bool

    package init(id: String, name: String, cwd: String, pid: Int?, tty: String?,
                 status: String?, entrypoint: String?, isCaller: Bool) {
        self.id = id; self.name = name; self.cwd = cwd; self.pid = pid; self.tty = tty
        self.status = status; self.entrypoint = entrypoint; self.isCaller = isCaller
    }
}

package struct ControlResponse: Codable, Equatable {
    package var ok: Bool
    package var message: String
    /// Which session the app decided the request came from, if any.
    package var callerSession: String?
    /// Which session was acted on, if any.
    package var targetSession: String?
    package var targetTTY: String?
    package var sessions: [ControlSessionInfo]?
    package var output: String?
    package var appVersion: String?
    /// spawn only: true once the new session appeared in the registry, false when the
    /// launcher succeeded but no session showed up in time. Nil for other verbs and dry runs.
    package var verified: Bool?

    package init(ok: Bool, message: String, callerSession: String? = nil,
                 targetSession: String? = nil, targetTTY: String? = nil,
                 sessions: [ControlSessionInfo]? = nil, output: String? = nil,
                 appVersion: String? = nil, verified: Bool? = nil) {
        self.ok = ok; self.message = message; self.callerSession = callerSession
        self.targetSession = targetSession; self.targetTTY = targetTTY
        self.sessions = sessions; self.output = output; self.appVersion = appVersion
        self.verified = verified
    }

    package static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, message: message)
    }
}

// MARK: - CLI argument parsing (in Core so it is testable)

package enum ControlCLIParseError: Error, Equatable, CustomStringConvertible {
    case noVerb
    case unknownVerb(String)
    case missingValue(String)
    case unexpected(String)
    case spawnNeedsDir
    case invalidAgent(String)
    case conflict(String)

    package var description: String {
        switch self {
        case .noVerb:                 return "no verb given"
        case .unknownVerb(let v):     return "unknown verb '\(v)'"
        case .missingValue(let f):    return "\(f) needs a value"
        case .unexpected(let a):      return "unexpected argument '\(a)'"
        case .spawnNeedsDir:          return "spawn needs a project directory"
        case .invalidAgent(let a):    return "invalid agent name '\(a)' (letters, digits, . _ - up to 64)"
        case .conflict(let m):        return m
        }
    }
}

package enum ControlCLIArgs {
    package static let usage: String = {
        var s = "usage: claudedeck <verb> [options]\n\n"
        for v in ControlVerb.allCases { s += "  \(v.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(v.summary)\n" }
        s += "\nOptions:\n"
        s += "  --session ID    target another session (compact/clear). Requires an owner grant.\n"
        s += "  --agent NAME    lane name; the session registers itself on the bridge as NAME\n"
        s += "  --prompt TEXT   initial prompt for the spawned session\n"
        s += "  --screen        spawn in a detached GNU screen session\n"
        s += "  --background    spawn headless (needs --prompt)\n"
        s += "  --terminal NAME force the terminal for spawn (iterm|terminal)\n"
        s += "  --dry-run       show what spawn would do; launch nothing\n"
        s += "  --wake TEXT     message typed after /compact finishes (default: a generic continue)\n"
        s += "  --no-wake       do not type a wake message after /compact\n"
        s += "  --json          print the raw response\n"
        return s
    }()

    package struct Parsed: Equatable {
        package var request: ControlRequest
        package var json: Bool
    }

    package static func parse(_ argv: [String], env: [String: String] = ProcessInfo.processInfo.environment) throws -> Parsed {
        var args = argv[...]
        guard let verbRaw = args.popFirst() else { throw ControlCLIParseError.noVerb }
        guard let verb = ControlVerb(rawValue: verbRaw) else { throw ControlCLIParseError.unknownVerb(verbRaw) }

        var req = ControlRequest(verb: verb.rawValue)
        req.callerSessionHint = env["CLAUDE_CODE_SESSION_ID"]
        req.callerPidHint = env["CLAUDE_PID"].flatMap(Int.init)
        var json = false
        var positional: [String] = []

        func value(_ flag: String) throws -> String {
            guard let v = args.popFirst() else { throw ControlCLIParseError.missingValue(flag) }
            return v
        }

        while let a = args.popFirst() {
            switch a {
            case "--session":
                let v = try value(a)
                guard !v.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlCLIParseError.missingValue(a) }
                req.targetSession = v
            case "--agent":      req.agent = try value(a)
            case "--prompt":     req.prompt = try value(a)
            case "--wake":       req.wake = try value(a)
            case "--no-wake":    req.noWake = true
            case "--screen":     req.screen = true
            case "--background": req.background = true
            case "--terminal":   req.terminal = try value(a)
            case "--dry-run":    req.dryRun = true
            case "--json":       json = true
            case "--":           positional.append(contentsOf: args); args = [][...]
            default:
                if a.hasPrefix("--") { throw ControlCLIParseError.unexpected(a) }
                positional.append(a)
            }
        }

        switch verb {
        case .spawn:
            guard let dir = positional.first else { throw ControlCLIParseError.spawnNeedsDir }
            req.dir = dir
            if positional.count > 1 {
                let rest = positional.dropFirst().joined(separator: " ")
                req.prompt = req.prompt.map { $0 + " " + rest } ?? rest
            }
            if req.background == true && (req.prompt ?? "").isEmpty {
                throw ControlCLIParseError.conflict("--background needs --prompt")
            }
            if req.screen == true && req.background == true {
                throw ControlCLIParseError.conflict("--screen and --background are exclusive")
            }
            if let a = req.agent, !ControlRequest.isValidAgentName(a) {
                throw ControlCLIParseError.invalidAgent(a)
            }
        case .compact:
            if req.wake != nil && req.noWake == true {
                throw ControlCLIParseError.conflict("--wake and --no-wake are exclusive")
            }
            if let extra = positional.first { throw ControlCLIParseError.unexpected(extra) }
        case .clear, .ping, .sessions:
            if let extra = positional.first { throw ControlCLIParseError.unexpected(extra) }
        }
        return Parsed(request: req, json: json)
    }
}
