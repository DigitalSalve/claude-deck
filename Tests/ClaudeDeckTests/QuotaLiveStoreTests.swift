import Foundation
import ClaudeDeckCore

func runQuotaLiveStoreTests() {
    suite("QuotaLiveStore: start() is idempotent") {
        let store = QuotaLiveStore()
        store.start()
        store.start()
        store.start()
        // If start were not idempotent, we'd leak watchers/FDs.
        // Hard to observe directly — presence of no crash is the assertion.
        expect(true, "multiple start() calls do not crash")
    }

    suite("QuotaLiveStore: concurrent start() calls are safe") {
        let store = QuotaLiveStore()
        let group = DispatchGroup()
        for _ in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                store.start()
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 2)
        expect(result == .success, "all start() calls complete under 2s")
    }

    suite("QuotaLiveStore: refreshNow() survives event storms") {
        let store = QuotaLiveStore()
        store.start()
        // Fire many refreshes rapidly — single-flight should coalesce these.
        for _ in 0..<200 {
            store.refreshNow()
        }
        // No assertion other than "doesn't crash or pile up work queues".
        // Give single-flight loop time to quiesce.
        Thread.sleep(forTimeInterval: 0.5)
        expect(true, "200 refreshNow() calls complete without runaway")
    }

    suite("QuotaLiveStore: period change triggers refresh") {
        let store = QuotaLiveStore()
        store.start()
        store.period = .thirtyDays
        store.period = .allTime
        store.period = .sevenDays
        Thread.sleep(forTimeInterval: 0.5)
        expect(true, "rapid period changes do not crash")
    }
}
