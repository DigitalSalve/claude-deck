import Foundation
import ClaudeDeckCore

func runModelCatalogTests() {
    let catalog = ModelCatalog(overridesURL: nil, learnedURL: nil)

    suite("ModelCatalog — Parse") {
        let p = ModelCatalog.parse("claude-fable-5-1")
        expectEqual(p?.family, .fable, "fable family parsed")
        expectEqual(p?.version, "5.1", "fable version 5.1")
        expectEqual(p?.baseId, "claude-fable-5-1", "base id unchanged")

        let dated = ModelCatalog.parse("claude-sonnet-4-5-20250929")
        expectEqual(dated?.family, .sonnet, "dated sonnet family")
        expectEqual(dated?.version, "4.5", "date suffix not part of version")
        expectEqual(dated?.baseId, "claude-sonnet-4-5", "date suffix stripped from base id")

        let legacy = ModelCatalog.parse("claude-3-5-sonnet-20241022")
        expectEqual(legacy?.family, .sonnet, "legacy order family")
        expectEqual(legacy?.version, "3.5", "legacy order version")
        expectEqual(legacy?.baseId, "claude-3-5-sonnet", "legacy base id")

        expectEqual(ModelCatalog.parse("claude-opus-6")?.version, "6", "major-only version")
        expectEqual(ModelCatalog.parse("claude-opus-6")?.displayName, "Opus 6", "display from parse")
        expectNil(ModelCatalog.parse("gpt-5"), "non-claude id does not parse")
        expectEqual(ModelCatalog.parse("claude-zeta-7")?.family, .unknown, "unknown family still parses")
        expectEqual(ModelCatalog.parse("CLAUDE-OPUS-5-5")?.family, .opus, "case-insensitive")
    }

    suite("ModelCatalog — Exact resolution") {
        let f = catalog.resolve("claude-fable-5-1")
        expectEqual(f.family, .fable, "fable 5.1 family")
        expectEqual(f.displayName, "Fable 5.1", "fable 5.1 name")
        expectEqual(f.pricingSource, .exact, "fable 5.1 exact pricing")
        expectEqual(f.pricing.input, 10, "fable input $10")
        expectEqual(f.pricing.output, 50, "fable output $50")

        let o = catalog.resolve("claude-opus-5-5")
        expectEqual(o.pricing, ModelPricing(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5.0), "opus 5.5 rates")

        let dated = catalog.resolve("claude-sonnet-4-5-20250929")
        expectEqual(dated.pricingSource, .exact, "dated id resolves to its base entry")
        expectEqual(dated.displayName, "Sonnet 4.5", "dated id display name")
    }

    suite("ModelCatalog — Family fallback for unseen versions") {
        let o6 = catalog.resolve("claude-opus-6")
        expectEqual(o6.family, .opus, "unseen opus keeps opus family")
        expectEqual(o6.displayName, "Opus 6", "unseen opus named from id")
        expectEqual(o6.pricingSource, .familyFallback, "unseen opus flagged as fallback")
        expectEqual(o6.pricing, catalog.resolve("claude-opus-5-5").pricing, "fallback borrows newest opus rates")

        let f6 = catalog.resolve("claude-fable-6-2")
        expectEqual(f6.family, .fable, "unseen fable keeps fable family")
        expectEqual(f6.displayName, "Fable 6.2", "unseen fable named from id")
        expect(f6.isPriced, "fallback is still priced")

        let h = catalog.resolve("claude-haiku-7-20270101")
        expectEqual(h.family, .haiku, "dated unseen haiku keeps family")
        expectEqual(h.version, "7", "dated unseen haiku version")
    }

    suite("ModelCatalog — Unknown") {
        let g = catalog.resolve("gpt-9")
        expectEqual(g.family, .unknown, "foreign id is unknown")
        expectEqual(g.pricingSource, .none, "foreign id unpriced")
        expectEqual(g.pricing, .zero, "foreign id zero rates")
        expectEqual(g.displayName, "gpt-9", "foreign id shown raw")

        let syn = catalog.resolve("<synthetic>")
        expectEqual(syn.family, .unknown, "synthetic is unknown")
        expectEqual(syn.displayName, "Synthetic", "synthetic prettified")

        let z = catalog.resolve("claude-zeta-7")
        expectEqual(z.family, .unknown, "unknown claude family is unknown")
        expectEqual(z.displayName, "zeta-7", "unknown claude family shown without prefix")

        expectEqual(catalog.resolve(nil).family, .unknown, "nil is unknown")
        expectEqual(catalog.resolve("").family, .unknown, "empty is unknown")
    }

    suite("ModelCatalog — Learned marketing names") {
        let c = ModelCatalog(overridesURL: nil, learnedURL: nil)
        expectEqual(c.resolve("claude-opus-6").displayName, "Opus 6", "before learning: parsed name")
        c.learn(id: "claude-opus-6", marketingName: "Opus 6 Preview")
        expectEqual(c.resolve("claude-opus-6").displayName, "Opus 6 Preview", "after learning: marketing name")
        expectEqual(c.resolve("claude-opus-6").family, .opus, "learning does not change family")

        let line = Data(#"{"attachment":{"type":"model","identity":{"modelId":"claude-opus-6","marketingName":"Opus Six","knowledgeCutoff":"x"}}}"#.utf8)
        QuotaAnalyzer.learnModelIdentity(from: line, into: c)
        expectEqual(c.resolve("claude-opus-6").displayName, "Opus Six", "analyzer record feeds the catalog")
    }

    suite("ModelCatalog — Overrides file") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudedeck-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("models.json")
        let json = #"{"claude-opus-6":{"family":"opus","displayName":"Opus 6","input":4,"output":20},"acme-llm":{"family":"unknown","displayName":"Acme","input":1,"output":2,"cacheRead":0.1,"cacheWrite":1.25}}"#
        try? Data(json.utf8).write(to: url)
        let c = ModelCatalog(overridesURL: url, learnedURL: nil)

        let o = c.resolve("claude-opus-6")
        expectEqual(o.pricingSource, .exact, "override makes unseen id exact")
        expectEqual(o.pricing.cacheRead, 0.4, "override derives cache read as 10% of input")
        expectEqual(o.pricing.cacheWrite, 5.0, "override derives cache write as 125% of input")

        let a = c.resolve("acme-llm")
        expectEqual(a.displayName, "Acme", "non-claude override honoured")
        expectEqual(a.pricing.input, 1, "non-claude override priced")
        expectEqual(a.pricingSource, .exact, "non-claude override exact")

        try? FileManager.default.removeItem(at: dir)
    }

    suite("ModelCatalog — Pricing cost") {
        let p = ModelPricing(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)
        expect(abs(p.cost(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000) - 14.7) < 0.0001,
               "cost sums all four token classes")
        expectEqual(ModelPricing.standard(input: 10, output: 50).cacheWrite, 12.5, "standard cache write 125%")
        expectEqual(ModelPricing.standard(input: 10, output: 50).cacheRead, 1.0, "standard cache read 10%")
    }
}
