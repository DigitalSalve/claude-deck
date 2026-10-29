import Foundation
import ClaudeDeckCore

func runTokenCacheTests() {
    suite("TokenCache — windowTotal") {
        let now = Date()
        var cache = TokenCache()
        cache.entries = [
            TokenEntry(messageTimestamp: now.addingTimeInterval(-4 * 3600), tokens: 1000, sessionId: "a"),
            TokenEntry(messageTimestamp: now.addingTimeInterval(-2 * 3600), tokens: 2000, sessionId: "a"),
            TokenEntry(messageTimestamp: now.addingTimeInterval(-1 * 3600), tokens: 3000, sessionId: "b"),
        ]
        let windowStart = now.addingTimeInterval(-3 * 3600)
        expectEqual(cache.windowTotal(since: windowStart), 5000, "sums entries after windowStart")

        var old = TokenCache()
        old.entries = [TokenEntry(messageTimestamp: now.addingTimeInterval(-6 * 3600), tokens: 9999, sessionId: "a")]
        expectEqual(old.windowTotal(since: now.addingTimeInterval(-5 * 3600)), 0, "excludes old entries")

        expectEqual(TokenCache().windowTotal(since: now), 0, "empty cache = 0")

        var exact = TokenCache()
        exact.entries = [TokenEntry(messageTimestamp: now, tokens: 500, sessionId: "a")]
        expectEqual(exact.windowTotal(since: now), 500, "includes exact boundary")
    }

    suite("TokenCache — prune") {
        let now = Date()
        var cache = TokenCache()
        cache.entries = [
            TokenEntry(messageTimestamp: now.addingTimeInterval(-8 * 3600), tokens: 100, sessionId: "a"),
            TokenEntry(messageTimestamp: now.addingTimeInterval(-6 * 3600), tokens: 200, sessionId: "a"),
            TokenEntry(messageTimestamp: now.addingTimeInterval(-1 * 3600), tokens: 300, sessionId: "a"),
        ]
        cache.prune(before: now.addingTimeInterval(-7 * 3600))
        expectEqual(cache.entries.count, 2, "prune removes old entries")
        expectEqual(cache.entries.map(\.tokens).sorted(), [200, 300], "correct entries remain")

        var all = TokenCache()
        all.entries = [TokenEntry(messageTimestamp: now.addingTimeInterval(-10 * 3600), tokens: 999, sessionId: "a")]
        all.prune(before: now)
        expect(all.entries.isEmpty, "prune all entries")
    }

    suite("TokenCache — expireAnchorIfNeeded") {
        var recent = TokenCache()
        recent.windowAnchor = Date().addingTimeInterval(-4 * 3600)
        recent.expireAnchorIfNeeded()
        expect(recent.windowAnchor != nil, "4h-old anchor not expired")

        var old = TokenCache()
        old.windowAnchor = Date().addingTimeInterval(-5 * 3600 - 1)
        old.expireAnchorIfNeeded()
        expectNil(old.windowAnchor, "5h+ anchor expired")

        var nilAnchor = TokenCache()
        nilAnchor.windowAnchor = nil
        nilAnchor.expireAnchorIfNeeded()
        expectNil(nilAnchor.windowAnchor, "nil anchor stays nil")
    }

    suite("TokenCache — earliestTimestamp") {
        let now = Date()
        let t1 = now.addingTimeInterval(-3 * 3600)
        let t2 = now.addingTimeInterval(-1 * 3600)
        var cache = TokenCache()
        cache.entries = [
            TokenEntry(messageTimestamp: t2, tokens: 100, sessionId: "a"),
            TokenEntry(messageTimestamp: t1, tokens: 200, sessionId: "a"),
            TokenEntry(messageTimestamp: now, tokens: 300, sessionId: "b"),
        ]
        expectEqual(cache.earliestTimestamp(for: ["a"]), t1, "earliest for session a")
        expectNil(cache.earliestTimestamp(for: ["z"]), "nil when no match")
        expectNil(TokenCache().earliestTimestamp(for: ["a"]), "nil for empty cache")
    }

    suite("TokenCache — Codable round-trip") {
        let now = Date()
        var cache = TokenCache()
        cache.windowAnchor = now
        cache.fileOffsets = ["s1": 4096, "s2": 8192]
        cache.entries = [TokenEntry(messageTimestamp: now, tokens: 1000, sessionId: "s1")]

        if let data = try? JSONEncoder().encode(cache),
           let decoded = try? JSONDecoder().decode(TokenCache.self, from: data) {
            expectEqual(decoded.fileOffsets["s1"], 4096, "fileOffset s1 round-trips")
            expectEqual(decoded.fileOffsets["s2"], 8192, "fileOffset s2 round-trips")
            expectEqual(decoded.entries.count, 1, "entry count round-trips")
            expectEqual(decoded.entries[0].tokens, 1000, "token count round-trips")
            let diff = abs((decoded.windowAnchor?.timeIntervalSince1970 ?? 0) - now.timeIntervalSince1970)
            expect(diff < 1.0, "windowAnchor round-trips within 1s")
        } else {
            expect(false, "Codable round-trip should not throw")
        }
    }
}
