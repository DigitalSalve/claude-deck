import Darwin
import Foundation
import AppKit

package struct DispatchLauncher {

    package static let pidFile = "/tmp/.claude_dispatch_session.pid"

    // MARK: - State

    /// True if a dispatch session started by ClaudeDeck is still alive.
    package static var isRunning: Bool {
        guard let contents = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return kill(pid_t(pid), 0) == 0
    }

    // MARK: - Launch

    /// Launch a new dispatch session. If one is already running, brings Warp to front instead.
    package static func launch() {
        guard !isRunning else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Warp.app"))
            return
        }

        let claudePath = resolvedClaudePath()
        let pid = pidFile

        // Shell command that writes its PID and cleans up on exit.
        // $$ expands to the shell PID; trap removes the file when the shell exits.
        // Warp runs `exec:` in a shell, so $$ / trap / ; all work as written.
        let command = """
        echo '=== CLAUDE DISPATCH SESSION ==='; echo 'Started: '$(date); echo '================================'; echo ''; echo $$ > \(pid); trap 'rm -f \(pid)' EXIT; \(claudePath)
        """

        TerminalLauncher.launchITermCommand(cwd: NSHomeDirectory(), command: command)
    }

    // MARK: - Private

    private static func resolvedClaudePath() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "whence -p claude 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? "/opt/homebrew/bin/claude" : output
    }
}
