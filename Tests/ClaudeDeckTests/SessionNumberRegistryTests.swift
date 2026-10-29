import Foundation
import ClaudeDeckCore

func runSessionNumberRegistryTests() {
    // The registry is a process-wide singleton tied to ~/.claude/.
    // We test behavioral invariants that don't depend on starting state.

    suite("SessionNumberRegistry: stable assignments") {
        let reg = SessionNumberRegistry.shared
        let id = "stable-test-\(UUID().uuidString)"
        let first = reg.number(for: id)
        let second = reg.number(for: id)
        let third = reg.number(for: id)
        expectEqual(first, second, "same id returns same number (2nd call)")
        expectEqual(first, third, "same id returns same number (3rd call)")
    }

    suite("SessionNumberRegistry: monotonic for new ids") {
        let reg = SessionNumberRegistry.shared
        let a = reg.number(for: "mono-a-\(UUID().uuidString)")
        let b = reg.number(for: "mono-b-\(UUID().uuidString)")
        let c = reg.number(for: "mono-c-\(UUID().uuidString)")
        expect(b > a, "second assignment > first")
        expect(c > b, "third assignment > second")
    }

    suite("SessionNumberRegistry: numberIfKnown read-only") {
        let reg = SessionNumberRegistry.shared
        let id = "readonly-\(UUID().uuidString)"
        expectNil(reg.numberIfKnown(for: id), "unknown id returns nil")
        let assigned = reg.number(for: id)
        expectEqual(reg.numberIfKnown(for: id), assigned, "known id returned after assignment")
        // Calling numberIfKnown on a fresh id must not assign.
        let freshId = "readonly-fresh-\(UUID().uuidString)"
        _ = reg.numberIfKnown(for: freshId)
        expectNil(reg.numberIfKnown(for: freshId), "numberIfKnown did not assign")
    }

    suite("SessionNumberRegistry: concurrent access safety") {
        let reg = SessionNumberRegistry.shared
        let group = DispatchGroup()
        let ids = (0..<20).map { "concurrent-\(UUID().uuidString)-\($0)" }
        var numbers: [Int] = Array(repeating: 0, count: ids.count)
        let numbersLock = NSLock()
        for (idx, id) in ids.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                let n = reg.number(for: id)
                numbersLock.lock(); numbers[idx] = n; numbersLock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 3)
        let unique = Set(numbers)
        expectEqual(unique.count, ids.count, "20 concurrent assignments produced 20 unique numbers")
    }
}
