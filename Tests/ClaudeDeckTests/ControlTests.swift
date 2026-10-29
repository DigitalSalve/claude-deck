import Foundation
import ClaudeDeckCore

func runControlTests() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-control-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let policy = InjectionPolicy(directory: tmp)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func writeRoles(_ ids: [(String, String)]) {
        let sessions = ids.map { ["session_id": $0.0, "owner_word": $0.1] }
        let data = try! JSONSerialization.data(withJSONObject: ["sessions": sessions])
        try! data.write(to: policy.rolesURL)
    }
    func writeGrant(tty: String, word: String, grantedAt: Double) {
        let data = try! JSONSerialization.data(withJSONObject: ["tty": tty, "owner_word": word, "granted_at": grantedAt, "content": ""])
        try! data.write(to: policy.grantURL)
    }

    suite("InjectionPolicy — self and human are always allowed") {
        expectEqual(policy.evaluate(callerSession: "A", targetSession: "A", targetTTY: "/dev/ttys001", now: now), .allowSelf, "self target")
        expectEqual(policy.evaluate(callerSession: nil, targetSession: "A", targetTTY: "/dev/ttys001", now: now), .allowHuman, "no caller session = owner shell")
        expectEqual(policy.evaluate(callerSession: "", targetSession: "A", targetTTY: nil, now: now), .allowHuman, "empty caller = owner shell")
    }

    suite("InjectionPolicy — peer requires role") {
        try? FileManager.default.removeItem(at: policy.rolesURL)
        let d = policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: "/dev/ttys002", now: now)
        expect(!d.isAllowed, "no roles file = denied")
        if case .deny(let why) = d { expect(why.contains("orchestrator role"), "denial names the role gate") }
        writeRoles([("A", "   ")])
        expect(!policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: nil, now: now).isAllowed, "blank owner_word = no role")
        writeRoles([("Z", "you are in charge")])
        expect(!policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: nil, now: now).isAllowed, "other session's role does not count")
    }

    suite("InjectionPolicy — peer requires live grant") {
        writeRoles([("A", "you are in charge")])
        try? FileManager.default.removeItem(at: policy.grantURL)
        let noGrant = policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: "/dev/ttys002", now: now)
        if case .deny(let why) = noGrant { expect(why.contains("none exists"), "no grant = denied, says none exists") } else { expect(false, "no grant must deny") }

        writeGrant(tty: "/dev/ttys002", word: "  ", grantedAt: now.timeIntervalSince1970)
        if case .deny(let why) = policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: "/dev/ttys002", now: now) {
            expect(why.contains("no owner_word"), "blank owner word denied")
        } else { expect(false, "blank owner word must deny") }

        writeGrant(tty: "/dev/ttys002", word: "go", grantedAt: now.timeIntervalSince1970 - 601)
        if case .deny(let why) = policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: "/dev/ttys002", now: now) {
            expect(why.contains("expired"), "601s old grant expired")
        } else { expect(false, "expired grant must deny") }
        expect(!FileManager.default.fileExists(atPath: policy.grantURL.path), "expired grant file removed")

        writeGrant(tty: "/dev/ttys009", word: "go", grantedAt: now.timeIntervalSince1970 - 10)
        if case .deny(let why) = policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: "/dev/ttys002", now: now) {
            expect(why.contains("One grant, one target"), "tty mismatch denied")
        } else { expect(false, "tty mismatch must deny") }

        writeGrant(tty: "/dev/ttys002", word: "go", grantedAt: now.timeIntervalSince1970 - 10)
        expectEqual(policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: "/dev/ttys002", now: now), .allowPeer(grantTTY: "/dev/ttys002"), "role + fresh matching grant = allowed")
        expectEqual(policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: nil, now: now), .allowPeer(grantTTY: "/dev/ttys002"), "unknown target tty still honours the grant")

        policy.consumePeerGrant(targetTTY: "/dev/ttys002", commandHead: "claudedeck clear --session B", now: now)
        expect(!FileManager.default.fileExists(atPath: policy.grantURL.path), "grant consumed on use")
        let log = (try? String(contentsOf: policy.logURL, encoding: .utf8)) ?? ""
        expect(log.contains("\"via\":\"claudedeck\"") && log.contains("ttys002"), "audit line written")
        expect(!policy.evaluate(callerSession: "A", targetSession: "B", targetTTY: "/dev/ttys002", now: now).isAllowed, "second use without a new grant denied")
    }

    suite("ControlCLIArgs — parsing") {
        let env = ["CLAUDE_CODE_SESSION_ID": "abc", "CLAUDE_PID": "4242"]
        let p = try? ControlCLIArgs.parse(["compact", "--wake", "carry on"], env: env)
        expectEqual(p?.request.verb, "compact", "verb")
        expectEqual(p?.request.wake, "carry on", "wake text")
        expectEqual(p?.request.callerSessionHint, "abc", "caller hint from env")
        expectEqual(p?.request.callerPidHint, 4242, "pid hint from env")
        expectNil(p?.request.targetSession, "no --session = self")

        let peer = try? ControlCLIArgs.parse(["clear", "--session", "deadbeef", "--json"], env: env)
        expectEqual(peer?.request.targetSession, "deadbeef", "--session parsed")
        expectEqual(peer?.json, true, "--json parsed")

        let sp = try? ControlCLIArgs.parse(["spawn", "~/GitHub/x", "--agent", "lane-a", "start", "on", "X"], env: env)
        expectEqual(sp?.request.dir, "~/GitHub/x", "spawn dir")
        expectEqual(sp?.request.agent, "lane-a", "spawn agent")
        expectEqual(sp?.request.prompt, "start on X", "trailing words become the prompt")

        let sp2 = try? ControlCLIArgs.parse(["spawn", "/tmp", "--prompt", "hi", "--screen"], env: env)
        expectEqual(sp2?.request.prompt, "hi", "--prompt")
        expectEqual(sp2?.request.screen, true, "--screen")

        let sp3 = try? ControlCLIArgs.parse(["spawn", "/tmp", "--dry-run", "--terminal", "iterm"], env: env)
        expectEqual(sp3?.request.dryRun, true, "--dry-run")
        expectEqual(sp3?.request.terminal, "iterm", "--terminal")

        func err(_ a: [String]) -> ControlCLIParseError? {
            do { _ = try ControlCLIArgs.parse(a, env: env); return nil } catch { return error as? ControlCLIParseError }
        }
        expectEqual(err([]), .noVerb, "no verb")
        expectEqual(err(["dance"]), .unknownVerb("dance"), "unknown verb")
        expectEqual(err(["spawn"]), .spawnNeedsDir, "spawn without dir")
        expectEqual(err(["compact", "--session"]), .missingValue("--session"), "flag without value")
        expectEqual(err(["compact", "--wake", "x", "--no-wake"]), .conflict("--wake and --no-wake are exclusive"), "wake conflict")
        expectEqual(err(["spawn", "/tmp", "--background"]), .conflict("--background needs --prompt"), "background needs prompt")
        expectEqual(err(["spawn", "/tmp", "--agent", "bad name!"]), .invalidAgent("bad name!"), "agent name checked before the app (covers the no-app fallback)")
        expectEqual(err(["spawn", "/tmp", "--terminal"]), .missingValue("--terminal"), "--terminal needs a value")
        expect(ControlRequest.isValidAgentName("api-lane.a_1"), "lane name chars allowed")
        expect(!ControlRequest.isValidAgentName(String(repeating: "a", count: 65)), "lane name capped at 64")
        expectEqual(err(["clear", "extra"]), .unexpected("extra"), "stray positional")
        expectEqual(err(["compact", "--type", "rm -rf /"]), .unexpected("--type"), "no arbitrary-text flags exist")
        expect(ControlCLIArgs.usage.contains("compact"), "usage lists verbs")
    }

    suite("Control protocol — JSON round trip") {
        let req = ControlRequest(verb: "spawn", dir: "/x", agent: "a", prompt: "p", screen: true)
        let data = try! JSONEncoder().encode(req)
        expectEqual(try? JSONDecoder().decode(ControlRequest.self, from: data), req, "request round trip")
        let res = ControlResponse(ok: true, message: "m", targetSession: "t", sessions: [
            ControlSessionInfo(id: "i", name: "n", cwd: "/c", pid: 1, tty: "/dev/ttys001", status: "idle", entrypoint: "cli", isCaller: true)
        ])
        let rd = try! JSONEncoder().encode(res)
        expectEqual(try? JSONDecoder().decode(ControlResponse.self, from: rd), res, "response round trip")
        expectNil(ControlRequest(verb: "nope").parsedVerb, "unknown verb does not parse")
    }

    suite("CommandServer — handler without a socket") {
        var server = CommandServer()
        var paths = CommandServer.Paths()
        paths.sessionsDir = tmp.appendingPathComponent("sessions")
        paths.log = tmp.appendingPathComponent("cmd.log")
        paths.selfConsoleScript = tmp.appendingPathComponent("no-such-script.sh").path
        paths.launchScript = tmp.appendingPathComponent("no-such-launch.sh").path
        try? FileManager.default.createDirectory(at: paths.sessionsDir, withIntermediateDirectories: true)
        server.paths = paths
        server.policy = policy

        // A registry entry whose pid is this test process: alive, has a tty when run from a terminal.
        let me = ProcessInfo.processInfo.processIdentifier
        let reg = #"{"pid":\#(me),"sessionId":"self-session","cwd":"/tmp","kind":"interactive","entrypoint":"cli","status":"idle"}"#
        try! Data(reg.utf8).write(to: paths.sessionsDir.appendingPathComponent("\(me).json"))
        let dead = #"{"pid":999999,"sessionId":"dead-session","cwd":"/tmp","kind":"interactive","entrypoint":"cli"}"#
        try! Data(dead.utf8).write(to: paths.sessionsDir.appendingPathComponent("999999.json"))

        let ping = server.handle(ControlRequest(verb: "ping"), peerPid: Int(me))
        expect(ping.ok, "ping ok")
        expectEqual(ping.callerSession, "self-session", "caller resolved from the peer pid's ancestry")

        let list = server.handle(ControlRequest(verb: "sessions"), peerPid: nil)
        expectEqual(list.sessions?.count, 1, "dead registry entries are dropped")
        expectEqual(list.sessions?.first?.id, "self-session", "live entry listed")

        let bad = server.handle(ControlRequest(verb: "dance"), peerPid: nil)
        expect(!bad.ok && bad.message.contains("unknown verb"), "unknown verb rejected")

        let noDir = server.handle(ControlRequest(verb: "spawn", dir: "/no/such/dir/\(UUID())"), peerPid: nil)
        expect(!noDir.ok && noDir.message.contains("directory not found"), "spawn validates the directory")
        let noScript = server.handle(ControlRequest(verb: "spawn", dir: "/tmp"), peerPid: nil)
        expect(!noScript.ok && noScript.message.contains("launch script missing"), "spawn needs the launcher script")
        let badAgent = server.handle(ControlRequest(verb: "spawn", dir: "/tmp", agent: "bad name!"), peerPid: nil)
        expect(!badAgent.ok && badAgent.message.contains("invalid agent name"), "agent name validated")

        let noTarget = server.handle(ControlRequest(verb: "compact"), peerPid: nil)
        expect(!noTarget.ok && noTarget.message.contains("no target"), "compact from a plain shell needs --session")
        let unknown = server.handle(ControlRequest(verb: "clear", targetSession: "nope"), peerPid: nil)
        expect(!unknown.ok && unknown.message.contains("not in the live registry"), "unknown target rejected")

        // Peer denial path: caller = self-session (via ancestry), target = a second live entry (also this pid).
        let other = #"{"pid":\#(me),"sessionId":"other-session","cwd":"/tmp","kind":"interactive","entrypoint":"cli"}"#
        try! Data(other.utf8).write(to: paths.sessionsDir.appendingPathComponent("other.json"))
        try? FileManager.default.removeItem(at: policy.rolesURL)
        let denied = server.handle(ControlRequest(verb: "clear", targetSession: "other-session"), peerPid: Int(me))
        expect(!denied.ok, "peer clear without role is refused")
        expect(denied.message.hasPrefix("BLOCKED") || denied.message.contains("no controlling terminal") || denied.message.contains("script missing"),
               "refusal is a policy block (or no tty in a headless test run), never an injection: \(denied.message.prefix(60))")

        // Peer + role + grant + custom wake text: refused even though the grant is valid.
        writeRoles([("self-session", "you are in charge")])
        let myTTY = CommandServer.tty(ofPid: Int(me))
        if let myTTY {
            writeGrant(tty: myTTY, word: "go", grantedAt: Date().timeIntervalSince1970)
            let wake = server.handle(ControlRequest(verb: "compact", targetSession: "other-session", wake: "do something else"), peerPid: Int(me))
            expect(!wake.ok && wake.message.contains("--wake is not allowed on a peer"), "free wake text on a peer is refused despite a valid grant")
            expect(FileManager.default.fileExists(atPath: policy.grantURL.path), "refusal does not consume the grant")
            try? FileManager.default.removeItem(at: policy.grantURL)
        } else {
            expect(true, "no controlling tty in this test run; peer wake check skipped")
        }
        try? FileManager.default.removeItem(at: policy.rolesURL)

        let log = (try? String(contentsOf: paths.log, encoding: .utf8)) ?? ""
        expect(log.contains("ping") && log.contains("ERR clear"), "every request audited to the command log")
        _ = server
    }

    suite("CommandServer — spawn confirms the new session") {
        var server = CommandServer()
        var paths = CommandServer.Paths()
        paths.sessionsDir = tmp.appendingPathComponent("spawn-sessions")
        paths.log = tmp.appendingPathComponent("spawn.log")
        try? FileManager.default.createDirectory(at: paths.sessionsDir, withIntermediateDirectories: true)
        let project = tmp.appendingPathComponent("project")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let argsFile = tmp.appendingPathComponent("launcher-args")

        // Fake launcher: records its args; on a real launch, registers a session in the
        // project dir (pid = this test process, so it counts as alive) unless told not to.
        func launcher(registers: Bool) -> String {
            let path = tmp.appendingPathComponent("launch-\(registers).sh").path
            let entry = #"{"pid":\#(me),"sessionId":"new-session-\#(UUID().uuidString)","cwd":"\#(project.path)/","kind":"interactive","entrypoint":"cli","name":"project-1","status":"idle"}"#
            var body = "#!/bin/bash\nprintf '%s\\n' \"$@\" > '\(argsFile.path)'\n"
            body += "case \" $* \" in *' --dry-run '*) echo 'would launch'; exit 0 ;; esac\n"
            if registers { body += "echo '\(entry)' > '\(paths.sessionsDir.path)/new.json'\n" }
            body += "echo 'Launched Claude Code session'\n"
            try! body.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
            return path
        }
        server.spawnConfirmTimeout = 1

        paths.launchScript = launcher(registers: true)
        server.paths = paths
        let ok = server.handle(ControlRequest(verb: "spawn", dir: project.path, agent: "lane-a", prompt: "secret plan", screen: true, terminal: "iterm"), peerPid: nil)
        expect(ok.ok, "spawn ok: \(ok.message)")
        expectEqual(ok.verified, true, "new registry entry in the project dir confirms the launch")
        expect(ok.targetSession?.hasPrefix("new-session-") == true, "response names the new session")
        expectEqual(ok.sessions?.count, 1, "response carries the new session's info")
        let passed = (try? String(contentsOf: argsFile, encoding: .utf8)) ?? ""
        expect(passed.contains("--screen") && passed.contains("--agent\nlane-a") && passed.contains("--terminal\niterm"), "flags forwarded to the launcher")
        try? FileManager.default.removeItem(at: paths.sessionsDir.appendingPathComponent("new.json"))

        let dry = server.handle(ControlRequest(verb: "spawn", dir: project.path, dryRun: true), peerPid: nil)
        expect(dry.ok && dry.message.contains("dry run"), "dry run reported")
        expectNil(dry.verified, "dry run is not waited on")
        expect(((try? String(contentsOf: argsFile, encoding: .utf8)) ?? "").contains("--dry-run"), "--dry-run forwarded")

        // An existing session in the same dir is not mistaken for the new one.
        let existing = #"{"pid":\#(me),"sessionId":"already-here","cwd":"\#(project.path)","kind":"interactive","entrypoint":"cli"}"#
        try! Data(existing.utf8).write(to: paths.sessionsDir.appendingPathComponent("existing.json"))
        paths.launchScript = launcher(registers: false)
        server.paths = paths
        let unconfirmed = server.handle(ControlRequest(verb: "spawn", dir: project.path), peerPid: nil)
        expect(unconfirmed.ok, "launcher success is still ok")
        expectEqual(unconfirmed.verified, false, "no new registry entry = not confirmed, even with an older session in that dir")
        expect(unconfirmed.message.contains("not confirmed"), "message says not confirmed")

        let log = (try? String(contentsOf: paths.log, encoding: .utf8)) ?? ""
        expect(log.contains("agent=lane-a") && log.contains("mode=screen") && log.contains("terminal=iterm") && log.contains("prompt=yes"),
               "spawn audit line records how it was launched")
        expect(!log.contains("secret plan"), "prompt text never written to the audit log")
        expect(log.contains("dry-run"), "dry run audited")

        expectEqual(CommandServer.canonicalPath(project.path + "/"), CommandServer.canonicalPath(project.path), "trailing slash ignored")

        let detachedOut = "Launching Claude Code session\n  OS:        macOS\n  Mode:      detached screen (console locked)\n  Session:   cc-web\nStarted screen session cc-web.\n"
        let d = CommandServer.detachedSession(fromLauncherOutput: detachedOut)
        expectEqual(d?.mux, "screen", "detached mux parsed")
        expectEqual(d?.name, "cc-web", "detached session name parsed")
        expectEqual(CommandServer.detachedSession(fromLauncherOutput: "  Mode:      detached tmux (requested)\n  Session:   cc-x\n")?.mux, "tmux", "tmux parsed")
        expect(CommandServer.detachedSession(fromLauncherOutput: "  Mode:      terminal tab (iterm)\n") == nil, "tab launch is not detached")
        let trustScreen = " Accessing workspace:\n /Users/me/Github/x\n Quick safety check: Is this a project you created or one you trust?\n o No, exit\n Yes, I trust this folder\n"
        expect(CommandServer.startupBlocker(inScreen: trustScreen)?.contains("trust prompt") == true, "trust prompt recognised")
        expectNil(CommandServer.startupBlocker(inScreen: "> \n? for shortcuts"), "a normal idle prompt is not a blocker")
        let mixed = tmp.appendingPathComponent("CaseDir")
        try? FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
        let otherCase = tmp.appendingPathComponent("casedir").path
        if FileManager.default.fileExists(atPath: otherCase) {
            expectEqual(CommandServer.canonicalPath(otherCase), CommandServer.canonicalPath(mixed.path),
                        "typed case (~/GitHub) matches on-disk case (~/Github) on a case-insensitive volume")
            expect(CommandServer.canonicalPath(otherCase).hasSuffix("/CaseDir"), "canonical path uses the on-disk case")
        } else {
            expect(true, "case-sensitive volume; case folding check skipped")
        }
    }
}
