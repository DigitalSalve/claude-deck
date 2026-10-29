import SwiftUI
import ClaudeDeckCore

@main
struct ClaudeDeckApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Hoisted here so the detached Quota window shares the same watchers,
    /// cache, and parsed report as the main menubar popover. Creating two
    /// stores would double file-descriptor load and let the two windows
    /// drift against each other.
    @State private var quotaStore: QuotaLiveStore

    init() {
        // On a case-insensitive disk, .../MacOS/claudedeck is this app binary, not the
        // CLI. Run with a CLI verb it would start a second app that never exits, and the
        // caller's shell waits on it forever. Refuse and point at the real CLI.
        let args = CommandLine.arguments.dropFirst()
        let cliVerbs: Set<String> = ["ping", "sessions", "spawn", "compact", "clear", "usage", "statusline", "help", "-h", "--help"]
        if let first = args.first, cliVerbs.contains(first) {
            let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/bin/claudedeck").path
            FileHandle.standardError.write(Data("This is the ClaudeDeck app, not its CLI. Run: \(cli) \(args.joined(separator: " "))\n".utf8))
            exit(64)
        }

        // Started at launch (not on the Quota tab) so the usage ledger keeps
        // booking tokens whether or not the report is open.
        let store = QuotaLiveStore()
        store.start()
        _quotaStore = State(initialValue: store)

        // Control socket for the `claudedeck` CLI (spawn / compact / clear).
        // Started here, not in a view task, so it exists even before any
        // window is shown.
        CommandServer.shared.start()
        if let err = CommandServer.shared.lastError {
            NSLog("ClaudeDeck control socket failed to start: %@", err)
        } else {
            NSLog("ClaudeDeck control socket listening at %@", ControlProtocol.socketPath)
        }
    }

    var body: some Scene {
        Window("ClaudeDeck", id: "main") {
            ContentView(quotaStore: quotaStore)
                .task { TerminalInstallCheck.verifyOrPrompt() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 540, height: 650)
        .windowResizability(.contentSize)

        // Detached, resizable Quota window. Hidden from the app's menus until
        // the user clicks the pop-out button in the main window's Quota tab.
        // minWidth is set high enough that no row can be clipped at either
        // end — the scaled-up popped row needs ~640pt before the bar, so we
        // leave headroom for the bar and dots.
        Window("Quota Report", id: "quota") {
            QuotaReportView(store: quotaStore, isPoppedOut: true)
                .frame(
                    minWidth: 820, idealWidth: 980,
                    minHeight: 500, idealHeight: 640
                )
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                // Flush in-memory quota cache on backgrounding/termination
                // so the 10s persist debounce can't eat recent progress.
                QuotaAnalyzer.shared.persistCache()
                UsageLedger.shared.flush()
            }
        }
    }
}
