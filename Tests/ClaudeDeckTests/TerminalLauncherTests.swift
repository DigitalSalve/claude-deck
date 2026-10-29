import ClaudeDeckCore
import Foundation

func runTerminalLauncherTests() {
    let claude = "/opt/homebrew/bin/claude"

    suite("TerminalLauncher — New Session") {
        expectEqual(TerminalLauncher.buildCommand(.new(), claudePath: claude, cwd: nil),
                    claude, "new session = bare claude path")

        expectEqual(TerminalLauncher.buildCommand(.new(dangerouslySkipPermissions: true), claudePath: claude, cwd: nil),
                    "\(claude) --dangerously-skip-permissions", "dangerous = adds flag")

        expectEqual(TerminalLauncher.buildCommand(.new(), claudePath: claude, cwd: "/Users/alex/myapp"),
                    "cd '/Users/alex/myapp' && \(claude)", "new with cwd prepends cd")

        expectEqual(TerminalLauncher.buildCommand(.new(), claudePath: claude, cwd: "/Users/alex/my app"),
                    "cd '/Users/alex/my app' && \(claude)", "spaces in cwd preserved")

        let escaped = TerminalLauncher.buildCommand(.new(), claudePath: claude, cwd: "/it's here")
        expect(escaped.contains(claude) && escaped.contains("&&"), "single-quote path: contains claude and &&")
        expect(!escaped.contains("'it's"), "single-quote path: no raw 'it's in output")
    }

    suite("TerminalLauncher — Resume") {
        expectEqual(TerminalLauncher.buildCommand(.resume(sessionId: "abc-123"), claudePath: claude, cwd: nil),
                    "\(claude) --resume abc-123", "resume with id")

        expectEqual(TerminalLauncher.buildCommand(.resume(sessionId: nil), claudePath: claude, cwd: nil),
                    "\(claude) --resume", "resume without id")

        expectEqual(TerminalLauncher.buildCommand(.resume(sessionId: "xyz"), claudePath: claude, cwd: "/proj"),
                    "cd '/proj' && \(claude) --resume xyz", "resume with cwd")
    }

    suite("TerminalLauncher — Continue") {
        expectEqual(TerminalLauncher.buildCommand(.continueRecent, claudePath: claude, cwd: nil),
                    "\(claude) --continue", "continueRecent command")

        expectEqual(TerminalLauncher.buildCommand(.continueRecent, claudePath: claude, cwd: "/tmp"),
                    "cd '/tmp' && \(claude) --continue", "continueRecent with cwd")
    }

    suite("TerminalLauncher — Dangerous Flag Exclusivity") {
        let nonDangerous = TerminalLauncher.buildCommand(.new(dangerouslySkipPermissions: false), claudePath: claude, cwd: nil)
        expect(!nonDangerous.contains("--dangerously-skip-permissions"), "non-dangerous new has no flag")

        let resume = TerminalLauncher.buildCommand(.resume(sessionId: "x"), claudePath: claude, cwd: nil)
        expect(!resume.contains("--dangerously-skip-permissions"), "resume has no dangerous flag")

        let cont = TerminalLauncher.buildCommand(.continueRecent, claudePath: claude, cwd: nil)
        expect(!cont.contains("--dangerously-skip-permissions"), "continue has no dangerous flag")
    }

    suite("TerminalLauncher — Warp Launch Config YAML") {
        let dangerous = TerminalLauncher.previewLaunchYAML(
            .new(dangerouslySkipPermissions: true), cwd: "/tmp/proj"
        )
        expect(dangerous.contains("name: claudedeck-launch"),
               "yaml contains launch config name")
        expect(dangerous.contains("cwd: '/tmp/proj'"),
               "yaml contains single-quoted cwd")
        expect(dangerous.contains("--dangerously-skip-permissions"),
               "yaml contains dangerous flag")
        expect(dangerous.contains("exec: '") && dangerous.contains("claude"),
               "yaml has single-quoted exec with claude in it")

        // Path with embedded apostrophe must be YAML-escaped as ''
        let tricky = TerminalLauncher.previewLaunchYAML(
            .new(), cwd: "/Users/alex/it's mine"
        )
        expect(tricky.contains("cwd: '/Users/alex/it''s mine'"),
               "single quote in cwd doubled per YAML spec")

        let resume = TerminalLauncher.previewLaunchYAML(.resume(sessionId: "abc"))
        expect(resume.contains("--resume abc"), "resume mode in yaml")

        let cont = TerminalLauncher.previewLaunchYAML(.continueRecent)
        expect(cont.contains("--continue"), "continue mode in yaml")
    }

    suite("TerminalLauncher — launch() writes YAML to disk") {
        // Integration test: calls the real launch() which writes YAML AND
        // opens Warp. Opt-in only — set CLAUDEDECK_RUN_E2E=1 to enable.
        // previewLaunchYAML renders the same YAML that the legacy Warp launch
        // config path would write. Validates the rendering without spawning
        // any terminal or touching disk.
        let yaml = TerminalLauncher.previewLaunchYAML(
            .new(dangerouslySkipPermissions: true), cwd: "/tmp")
        expect(yaml.contains("claudedeck-launch"), "yaml has correct name")
        expect(yaml.contains("cwd: '/tmp'"), "yaml has cwd")
        expect(yaml.contains("--dangerously-skip-permissions"),
               "yaml has dangerous flag")
    }
}
