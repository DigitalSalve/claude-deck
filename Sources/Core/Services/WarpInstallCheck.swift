import Foundation
import AppKit

/// Verifies iTerm2 is installed. ClaudeDeck depends on iTerm2 as its
/// terminal — without it, every launch button is a no-op.
package enum TerminalInstallCheck {

    private static let itermBundleID = "com.googlecode.iterm2"
    private static let downloadURL = URL(string: "https://iterm2.com/")!

    /// Returns true if iTerm2 is installed and LaunchServices can resolve it.
    package static func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: itermBundleID) != nil
    }

    /// Show a blocking alert if iTerm2 is missing. Returns immediately if iTerm2
    /// is found. The alert offers to open the download page.
    @MainActor
    package static func verifyOrPrompt() {
        guard !isInstalled() else { return }

        let alert = NSAlert()
        alert.messageText = "iTerm2 is required"
        alert.informativeText = """
            ClaudeDeck uses iTerm2 as its terminal for launching Claude sessions. \
            iTerm2 doesn't appear to be installed.

            Install iTerm2 from iterm2.com, then restart ClaudeDeck.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open iterm2.com")
        alert.addButton(withTitle: "Continue Anyway")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        }
    }
}
