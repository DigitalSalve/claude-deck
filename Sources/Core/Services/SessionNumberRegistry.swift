import Foundation

/// Assigns a stable, monotonically increasing short number to each session ID.
/// The number persists across app launches so you can say "the waste is in #47"
/// and find #47 in both the Active and Quota tabs.
package final class SessionNumberRegistry {
    package static let shared = SessionNumberRegistry()

    private let storeURL: URL
    private let lock = NSLock()
    private var mapping: [String: Int] = [:]
    private var nextNumber: Int = 1
    private let schemaVersion = 1

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        storeURL = home.appendingPathComponent(".claude/claudedeck-session-numbers.json")
        loadFromDisk()
    }

    /// Returns the stable number for this session. Assigns a new one if unseen.
    /// Persists the assignment immediately — first-number-ever is the only write.
    package func number(for sessionId: String) -> Int {
        lock.lock()
        if let existing = mapping[sessionId] { lock.unlock(); return existing }
        let assigned = nextNumber
        mapping[sessionId] = assigned
        nextNumber += 1
        lock.unlock()
        persist()
        return assigned
    }

    /// Read-only lookup — does not assign. Use when you don't want to create
    /// a number as a side effect.
    package func numberIfKnown(for sessionId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return mapping[sessionId]
    }

    // MARK: - Persistence

    private struct Envelope: Codable {
        let version: Int
        let nextNumber: Int
        let mapping: [String: Int]
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storeURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == schemaVersion
        else { return }
        mapping = envelope.mapping
        nextNumber = max(envelope.nextNumber, (mapping.values.max() ?? 0) + 1)
    }

    private func persist() {
        lock.lock()
        let envelope = Envelope(
            version: schemaVersion, nextNumber: nextNumber, mapping: mapping
        )
        lock.unlock()
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        // Data.write(.atomic) already writes to tmp + renames atomically.
        // Don't double up with FileManager.replaceItemAt — it can hang
        // when the target file has extended attributes.
        try? data.write(to: storeURL, options: .atomic)
    }
}
