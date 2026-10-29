import Foundation
import AppKit

package enum LaunchMode {
    case new(dangerouslySkipPermissions: Bool = false)
    case resume(sessionId: String? = nil) // nil = interactive picker
    case continueRecent
}

package struct TerminalLauncher {

    package static func launch(_ mode: LaunchMode, cwd: String? = nil) {
        let claudePath = resolvedClaudePath()
        let command    = buildClaudeCommand(mode, claudePath: claudePath)
        let launchCwd  = cwd ?? NSHomeDirectory()
        launchInITerm(cwd: launchCwd, command: command)
    }

    /// Opens a new tab in the existing iTerm2 window (or creates one) and
    /// runs the given command. Uses iTerm2's native AppleScript dictionary —
    /// no Accessibility permission needed, only Automation scoped to iTerm.
    private static func launchInITerm(cwd: String, command: String) {
        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window
                write text "cd \(escapeForAppleScript(shellEscape(cwd))) && \(escapeForAppleScript(command))"
            end tell
        end tell
        """
        runOsascript(script)
    }

    /// Launches an arbitrary shell command in iTerm2 as a new tab.
    /// Used by DispatchLauncher for custom dispatch commands.
    package static func launchITermCommand(cwd: String, command: String) {
        launchInITerm(cwd: cwd, command: command)
    }

    /// Test seam: builds the YAML a launch would write, without touching disk
    /// or opening Warp. Same code path used by `launch()`.
    package static func previewLaunchYAML(_ mode: LaunchMode, cwd: String? = nil) -> String {
        let claudePath = resolvedClaudePath()
        let command    = buildClaudeCommand(mode, claudePath: claudePath)
        let launchCwd  = cwd ?? NSHomeDirectory()
        return renderLaunchConfigYAML(name: launchConfigName, cwd: launchCwd, command: command)
    }

    // MARK: - AppleScript helpers

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runOsascript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError  = Pipe()
        try? process.run()
        // Don't wait — let it run async so the UI doesn't block.
    }

    // MARK: - Warp Launch Config (kept for launchInNewWindow / previewLaunchYAML)

    private static let launchConfigName = "claudedeck-launch"

    private static var launchConfigDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".warp/launch_configurations")
    }

    private static func writeLaunchConfig(name: String, cwd: String, command: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: launchConfigDir, withIntermediateDirectories: true)
        let yaml = renderLaunchConfigYAML(name: name, cwd: cwd, command: command)
        let fileURL = launchConfigDir.appendingPathComponent("\(name).yaml")
        try? yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func renderLaunchConfigYAML(name: String, cwd: String, command: String) -> String {
        """
        ---
        name: \(name)
        windows:
          - tabs:
              - layout:
                  cwd: \(yamlSingleQuoted(cwd))
                  commands:
                    - exec: \(yamlSingleQuoted(command))
        """
    }

    private static func yamlSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - Command building

    private static func buildClaudeCommand(_ mode: LaunchMode, claudePath: String) -> String {
        switch mode {
        case .new(let dangerous):
            return dangerous
                ? "\(claudePath) --dangerously-skip-permissions"
                : claudePath
        case .resume(let sessionId):
            return sessionId.map { "\(claudePath) --resume \($0)" } ?? "\(claudePath) --resume"
        case .continueRecent:
            return "\(claudePath) --continue"
        }
    }

    /// Run `whence -p claude` in a login zsh (loads ~/.zprofile for Homebrew PATH,
    /// skips ~/.zshrc so no aliases interfere). Falls back to known Homebrew path.
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

    package static func buildCommand(_ mode: LaunchMode, claudePath: String, cwd: String?) -> String {
        var parts: [String] = []
        if let cwd { parts.append("cd \(shellEscape(cwd)) &&") }
        switch mode {
        case .new(let dangerous):
            parts.append(dangerous ? "\(claudePath) --dangerously-skip-permissions" : claudePath)
        case .resume(let sessionId):
            parts.append(sessionId.map { "\(claudePath) --resume \($0)" } ?? "\(claudePath) --resume")
        case .continueRecent:
            parts.append("\(claudePath) --continue")
        }
        return parts.joined(separator: " ")
    }

    private static func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
