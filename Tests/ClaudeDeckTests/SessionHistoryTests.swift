import Foundation
import ClaudeDeckCore

func runSessionHistoryTests() {
    suite("SessionHistory — Project Name") {
        expectEqual(makeHistory(projectPath: "-Users-alex-GitHub-my-project").projectName,
                    "project", "projectName decodes dashed path")
    }

    suite("SessionHistory — Source Type") {
        expect(makeHistory(entrypoint: nil).isCLI,              "nil entrypoint is CLI")
        expect(makeHistory(entrypoint: "cli").isCLI,            "cli is CLI")
        expect(makeHistory(entrypoint: "claude-desktop").isDesktop, "claude-desktop is Desktop")
        expect(!makeHistory(entrypoint: "claude-desktop").isCLI,   "Desktop is not CLI")
        expect(makeHistory(entrypoint: "web").isWeb,             "web is Web")
        expect(makeHistory(entrypoint: "claude-web").isWeb,      "claude-web is Web")
    }

    suite("SessionHistory — Model Detection") {
        expect(makeHistory(model: "claude-sonnet-4-5").isSonnet,  "sonnet model detected")
        expect(!makeHistory(model: "claude-opus-4").isSonnet,     "opus not sonnet")
        expect(makeHistory(model: "claude-opus-4").isOpus,        "opus model detected")
        expect(!makeHistory(model: "claude-haiku-4-5").isOpus,    "haiku not opus")
        expect(makeHistory(model: "claude-haiku-4-5").isHaiku,    "haiku model detected")
        expect(!makeHistory(model: "claude-sonnet-4-5").isHaiku,  "sonnet not haiku")
        expect(makeHistory(model: "claude-fable-5-1").isFable,    "fable model detected")
        expect(!makeHistory(model: "claude-fable-5-1").isSonnet,  "fable is NOT sonnet (was the old default)")
        expectEqual(makeHistory(model: nil).modelFamily, .unknown, "nil model is unknown, not sonnet")
        expectEqual(makeHistory(model: "<synthetic>").modelFamily, .unknown, "synthetic placeholder is unknown")
    }

    suite("SessionHistory — Estimated Cost (catalog rates)") {
        // Sonnet 4.5: $3/M in + $15/M out = $18 for 1M each
        let sonnet = makeHistory(model: "claude-sonnet-4-5", inputTokens: 1_000_000, outputTokens: 1_000_000)
        expect(abs(sonnet.estimatedCost - 18.0) < 0.001, "Sonnet 4.5 cost $18 for 1M in + 1M out")

        // Sonnet 5.5: $2/M in + $10/M out = $12
        let sonnet55 = makeHistory(model: "claude-sonnet-5-5", inputTokens: 1_000_000, outputTokens: 1_000_000)
        expect(abs(sonnet55.estimatedCost - 12.0) < 0.001, "Sonnet 5.5 cost $12 for 1M in + 1M out")

        // Opus 5.5: $4/M in + $20/M out = $24
        let opus = makeHistory(model: "claude-opus-5-5", inputTokens: 1_000_000, outputTokens: 1_000_000)
        expect(abs(opus.estimatedCost - 24.0) < 0.001, "Opus 5.5 cost $24 for 1M in + 1M out")

        // Fable 5.1: $10/M in + $50/M out = $60
        let fable = makeHistory(model: "claude-fable-5-1", inputTokens: 1_000_000, outputTokens: 1_000_000)
        expect(abs(fable.estimatedCost - 60.0) < 0.001, "Fable 5.1 cost $60 for 1M in + 1M out")

        // Haiku 5.5: $0.10/M in + $0.50/M out = $0.60
        let haiku = makeHistory(model: "claude-haiku-5-5", inputTokens: 1_000_000, outputTokens: 1_000_000)
        expect(abs(haiku.estimatedCost - 0.6) < 0.001, "Haiku 5.5 cost $0.60 for 1M in + 1M out")

        // Sonnet 4.5 cache: $0.30/M read + $3.75/M write = $4.05 for 1M each
        let cache = makeHistory(model: "claude-sonnet-4-5", cacheRead: 1_000_000, cacheWrite: 1_000_000)
        expect(abs(cache.estimatedCost - 4.05) < 0.001, "Sonnet 4.5 cache cost $4.05")

        let zero = makeHistory(model: "claude-sonnet-4-5")
        expect(zero.estimatedCost == 0.0, "zero tokens = zero cost")

        let unknown = makeHistory(model: "gpt-9", inputTokens: 1_000_000, outputTokens: 1_000_000)
        expect(unknown.estimatedCost == 0.0, "unknown model costs $0, never priced as Sonnet")
    }
}

private func makeHistory(
    projectPath: String = "test-project",
    model: String? = "claude-sonnet-4-5",
    entrypoint: String? = nil,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cacheRead: Int = 0,
    cacheWrite: Int = 0
) -> SessionHistory {
    SessionHistory(
        id: "test", projectPath: projectPath, lastActivity: Date(), messageCount: 0,
        totalInputTokens: inputTokens, totalCacheReadTokens: cacheRead,
        totalCacheWriteTokens: cacheWrite, totalOutputTokens: outputTokens,
        model: model, name: nil, entrypoint: entrypoint
    )
}
