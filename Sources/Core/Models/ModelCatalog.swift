import Foundation

// MARK: - Model identity

/// Model families Claude Code can report in a transcript's `message.model`.
/// `unknown` covers ids this build has never seen and synthetic placeholders
/// such as `<synthetic>`; it must never be silently folded into another family.
package enum ModelFamily: String, Codable, CaseIterable {
    case fable, mythos, opus, sonnet, haiku, unknown

    package var label: String {
        switch self {
        case .fable:   return "Fable"
        case .mythos:  return "Mythos"
        case .opus:    return "Opus"
        case .sonnet:  return "Sonnet"
        case .haiku:   return "Haiku"
        case .unknown: return "?"
        }
    }
}

/// Per-million-token rates in USD.
package struct ModelPricing: Codable, Equatable {
    package var input: Double
    package var output: Double
    package var cacheRead: Double
    package var cacheWrite: Double

    package init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }

    /// Standard shape: cache read = 10% of input, cache write = 125% of input.
    package static func standard(input: Double, output: Double) -> ModelPricing {
        ModelPricing(input: input, output: output,
                     cacheRead: input * 0.10, cacheWrite: input * 1.25)
    }

    package static let zero = ModelPricing(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)

    package func cost(input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> Double {
        Double(input)      / 1_000_000 * self.input
      + Double(output)     / 1_000_000 * self.output
      + Double(cacheRead)  / 1_000_000 * self.cacheRead
      + Double(cacheWrite) / 1_000_000 * self.cacheWrite
    }
}

/// Where a resolved model's pricing came from. Surfaces in the UI so an
/// estimate built on a fallback is never mistaken for a priced model.
package enum PricingSource: String, Codable {
    /// Exact id in the built-in table or the user override file.
    case exact
    /// Id parsed to a known family; rates copied from the newest priced
    /// model in that family. Correct tier, approximate dollars.
    case familyFallback
    /// Unknown family or no model at all. Rates are zero.
    case none
}

package struct ModelInfo: Equatable {
    package let id: String?
    package let family: ModelFamily
    /// Dotted version parsed from the id, e.g. "5.1". Nil when absent.
    package let version: String?
    /// Human name: "Fable 5.1", "Opus 4.8", or the raw id when unparsed.
    package let displayName: String
    package let pricing: ModelPricing
    package let pricingSource: PricingSource

    package var isPriced: Bool { pricingSource != .none }
    /// Short badge text for list rows: the family label.
    package var shortLabel: String { family.label }
}

// MARK: - Catalog

/// Resolves any `message.model` string into a family, display name and
/// pricing. Resolution order:
///
/// 1. Exact id match — user override file first, then the built-in table.
/// 2. Family + version parse of `claude-<family>-<major>[-<minor>][-<date>]`
///    and the legacy `claude-<major>-<minor>-<family>[-<date>]` layout. The
///    family is authoritative; pricing is borrowed from that family's newest
///    priced entry and flagged `familyFallback`.
/// 3. Anything else is `unknown`, unpriced, displayed by its raw id.
///
/// Display names can also be learned at runtime from the `model` attachment
/// records Claude Code writes into transcripts (`identity.marketingName`), so
/// a model released after this build still shows its real name.
///
/// Override file: `~/.claude/claudedeck-models.json`
/// ```json
/// { "claude-opus-6": { "family": "opus", "displayName": "Opus 6",
///                      "input": 4, "output": 20, "cacheRead": 0.2, "cacheWrite": 5 } }
/// ```
package final class ModelCatalog: @unchecked Sendable {
    package static let shared = ModelCatalog()

    package struct Entry: Codable, Equatable {
        package var family: ModelFamily
        package var displayName: String?
        package var input: Double
        package var output: Double
        package var cacheRead: Double?
        package var cacheWrite: Double?

        package init(family: ModelFamily, displayName: String? = nil,
                     input: Double, output: Double,
                     cacheRead: Double? = nil, cacheWrite: Double? = nil) {
            self.family = family; self.displayName = displayName
            self.input = input; self.output = output
            self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        }

        package var pricing: ModelPricing {
            ModelPricing(input: input, output: output,
                         cacheRead: cacheRead ?? input * 0.10,
                         cacheWrite: cacheWrite ?? input * 1.25)
        }
    }

    /// Built-in table. Rates are Anthropic first-party API list prices
    /// (USD per MTok) as of 2026-10. Keep ordered newest-first within a
    /// family; `familyFallback` picks the first entry per family.
    package static let builtIn: [(id: String, entry: Entry)] = [
        // Fable / Mythos (same tier, same price)
        ("claude-fable-5-1",  Entry(family: .fable,  displayName: "Fable 5.1",  input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        ("claude-fable-5",    Entry(family: .fable,  displayName: "Fable 5",    input: 10, output: 50, cacheRead: 1.00, cacheWrite: 12.5)),
        ("claude-mythos-5-1", Entry(family: .mythos, displayName: "Mythos 5.1", input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        ("claude-mythos-5",   Entry(family: .mythos, displayName: "Mythos 5",   input: 10, output: 50, cacheRead: 1.00, cacheWrite: 12.5)),
        // Opus
        ("claude-opus-5-5",   Entry(family: .opus, displayName: "Opus 5.5", input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5.0)),
        ("claude-opus-5",     Entry(family: .opus, displayName: "Opus 5",   input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-8",   Entry(family: .opus, displayName: "Opus 4.8", input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-7",   Entry(family: .opus, displayName: "Opus 4.7", input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-6",   Entry(family: .opus, displayName: "Opus 4.6", input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-5",   Entry(family: .opus, displayName: "Opus 4.5", input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-1",   Entry(family: .opus, displayName: "Opus 4.1", input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75)),
        ("claude-opus-4",     Entry(family: .opus, displayName: "Opus 4",   input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75)),
        // Sonnet
        ("claude-sonnet-5-5", Entry(family: .sonnet, displayName: "Sonnet 5.5", input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5)),
        ("claude-sonnet-5",   Entry(family: .sonnet, displayName: "Sonnet 5",   input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5)),
        ("claude-sonnet-4-6", Entry(family: .sonnet, displayName: "Sonnet 4.6", input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-sonnet-4-5", Entry(family: .sonnet, displayName: "Sonnet 4.5", input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-sonnet-4",   Entry(family: .sonnet, displayName: "Sonnet 4",   input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-3-7-sonnet", Entry(family: .sonnet, displayName: "Sonnet 3.7", input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)),
        ("claude-3-5-sonnet", Entry(family: .sonnet, displayName: "Sonnet 3.5", input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)),
        // Haiku
        ("claude-haiku-5-5",  Entry(family: .haiku, displayName: "Haiku 5.5", input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)),
        ("claude-haiku-4-5",  Entry(family: .haiku, displayName: "Haiku 4.5", input: 1.00, output: 5.00, cacheRead: 0.10, cacheWrite: 1.25)),
        ("claude-3-5-haiku",  Entry(family: .haiku, displayName: "Haiku 3.5", input: 0.80, output: 4.00, cacheRead: 0.08, cacheWrite: 1.00)),
    ]

    private let lock = NSLock()
    private var overrides: [String: Entry] = [:]
    private var learnedNames: [String: String] = [:]
    private var cache: [String: ModelInfo] = [:]
    private let learnedURL: URL?

    package static let defaultOverridesURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedeck-models.json")
    package static let defaultLearnedURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedeck-models-learned.json")

    package convenience init() {
        self.init(overridesURL: Self.defaultOverridesURL, learnedURL: Self.defaultLearnedURL)
    }

    /// Testable init. Pass nil URLs for a pure in-memory catalog.
    package init(overridesURL: URL?, learnedURL: URL?) {
        self.learnedURL = learnedURL
        if let url = overridesURL,
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode([String: Entry].self, from: data) {
            overrides = parsed
        }
        if let url = learnedURL,
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
            learnedNames = parsed
        }
    }

    // MARK: Resolution

    package func resolve(_ id: String?) -> ModelInfo {
        guard let raw = id?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return ModelInfo(id: nil, family: .unknown, version: nil, displayName: "?",
                             pricing: .zero, pricingSource: .none)
        }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[raw] { return hit }
        let info = compute(raw)
        cache[raw] = info
        return info
    }

    package func family(of id: String?) -> ModelFamily { resolve(id).family }

    /// Record a model's marketing name as seen in a transcript `model`
    /// attachment record. Idempotent; persists when it changes something.
    package func learn(id: String, marketingName: String) {
        let name = marketingName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty else { return }
        lock.lock()
        let changed = learnedNames[id] != name
        if changed {
            learnedNames[id] = name
            cache[id] = nil
        }
        let snapshot = learnedNames
        lock.unlock()
        if changed, let url = learnedURL,
           let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Ids this catalog has resolved that carry no exact pricing. Lets the
    /// UI point the user at the override file.
    package func unpricedIdsSeen() -> [ModelInfo] {
        lock.lock(); defer { lock.unlock() }
        return cache.values
            .filter { $0.pricingSource != .exact && ($0.id.map { !$0.hasPrefix("<") } ?? false) }
            .sorted { ($0.id ?? "") < ($1.id ?? "") }
    }

    /// Every id the catalog has resolved this run, priced or not.
    package func idsSeen() -> [ModelInfo] {
        lock.lock(); defer { lock.unlock() }
        return cache.values
            .filter { $0.id.map { !$0.hasPrefix("<") } ?? false }
            .sorted { ($0.id ?? "") < ($1.id ?? "") }
    }

    // MARK: Internals

    private func compute(_ raw: String) -> ModelInfo {
        let id = raw.lowercased()

        // 1. Exact match: override, then built-in (date-suffixed ids strip
        //    to their base before the built-in lookup).
        if let e = overrides[id] { return make(raw, e, parsed: Self.parse(id), source: .exact) }
        let parsed = Self.parse(id)
        let base = parsed?.baseId ?? id
        if let e = overrides[base] { return make(raw, e, parsed: parsed, source: .exact) }
        if let e = Self.builtIn.first(where: { $0.id == base })?.entry {
            return make(raw, e, parsed: parsed, source: .exact)
        }

        // 2. Family fallback.
        if let p = parsed, p.family != .unknown {
            let newest = overrides.values.first { $0.family == p.family }
                ?? Self.builtIn.first { $0.entry.family == p.family }?.entry
            if let e = newest {
                return ModelInfo(id: raw, family: p.family, version: p.version,
                                 displayName: learnedNames[raw] ?? p.displayName,
                                 pricing: e.pricing, pricingSource: .familyFallback)
            }
        }

        // 3. Unknown.
        return ModelInfo(id: raw, family: .unknown, version: parsed?.version,
                         displayName: learnedNames[raw] ?? Self.prettify(raw),
                         pricing: .zero, pricingSource: .none)
    }

    private func make(_ raw: String, _ e: Entry, parsed: Parsed?, source: PricingSource) -> ModelInfo {
        ModelInfo(id: raw, family: e.family, version: parsed?.version,
                  displayName: learnedNames[raw] ?? e.displayName ?? parsed?.displayName ?? Self.prettify(raw),
                  pricing: e.pricing, pricingSource: source)
    }

    package struct Parsed: Equatable {
        package let family: ModelFamily
        package let version: String?
        /// Id with any trailing 8-digit date snapshot removed.
        package let baseId: String
        package var displayName: String {
            version.map { "\(family.label) \($0)" } ?? family.label
        }
    }

    /// Parses `claude-<family>-<major>[-<minor>][-<yyyymmdd>]` and the
    /// legacy `claude-<major>-<minor>-<family>[-<yyyymmdd>]`. Returns nil
    /// when the string is not a `claude-` id at all.
    package static func parse(_ rawId: String) -> Parsed? {
        let id = rawId.lowercased()
        guard id.hasPrefix("claude-") else { return nil }
        var parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }

        // Strip a trailing date snapshot (8 digits) or "latest".
        if let last = parts.last, (last.count == 8 && last.allSatisfy(\.isNumber)) || last == "latest" {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return nil }

        let familyIndex = parts.firstIndex { ModelFamily(rawValue: $0) != nil }
        let family = familyIndex.flatMap { ModelFamily(rawValue: parts[$0]) } ?? .unknown
        let numeric = parts.enumerated()
            .filter { $0.offset != familyIndex && $0.element.allSatisfy(\.isNumber) }
            .map(\.element)
        let version = numeric.isEmpty ? nil : numeric.joined(separator: ".")
        let baseId = "claude-" + parts.joined(separator: "-")
        return Parsed(family: family, version: version, baseId: baseId)
    }

    private static func prettify(_ raw: String) -> String {
        if raw.hasPrefix("<") { return "Synthetic" }
        return raw.hasPrefix("claude-") ? String(raw.dropFirst("claude-".count)) : raw
    }
}
