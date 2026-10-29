import SwiftUI
import ClaudeDeckCore

/// Control-request history for the Commands tab and the "queued" badge on
/// session rows. Reads the command log so the CLI's own fallback runs and
/// requests from before an app restart show too.
@Observable
final class CommandsModel {
    private(set) var entries: [CommandLogEntry] = []
    private(set) var pending = PendingCommands()
    private var lastSize: UInt64 = .max

    func reload(sessions: [ClaudeSession]) {
        let size = (try? FileManager.default.attributesOfItem(atPath: CommandLog.defaultURL.path)[.size] as? UInt64) ?? 0
        if size != lastSize {
            lastSize = size
            entries = CommandLog.load()
            let cutoff = Date().addingTimeInterval(-PendingCommands.timeout)
            for e in entries.reversed() where e.at > cutoff { pending.note(e) }
        }
        var live: [String: Bool] = [:]
        for s in sessions { live[s.id] = s.sessionStatus == .idle }
        var next = pending
        next.observe(live)
        if next != pending { pending = next }
    }
}

struct CommandsList: View {
    let entries: [CommandLogEntry]
    let sessions: [ClaudeSession]

    private func name(_ id: String?) -> String {
        guard let id else { return "you (shell)" }
        if let s = sessions.first(where: { $0.id == id }) {
            return "#\(SessionNumberRegistry.shared.number(for: id)) \(s.displayName)"
        }
        return String(id.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("No control requests yet. Sessions use `claudedeck spawn`, `compact` and `clear`; each one is listed here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            } else {
                ForEach(entries) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(e.ok ? .green : .red)
                            .help(e.ok ? "Allowed" : "Refused or failed")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(e.verb)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text(name(e.caller))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                if let t = e.target, t != e.caller {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                    Text(name(t))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(e.at, style: .relative)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(e.message)
                                .font(.system(size: 10))
                                .foregroundStyle(e.ok ? .secondary : .primary)
                                .lineLimit(2)
                                .help(e.detail.isEmpty ? e.message : "\(e.message)\n\(e.detail)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    Divider().padding(.leading, 35)
                }
                Text("From ~/.claude/claudedeck-commands.log (latest 100)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
    }
}
