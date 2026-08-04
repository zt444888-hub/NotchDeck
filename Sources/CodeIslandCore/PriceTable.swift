import Foundation

/// Per-model pricing in USD per 1,000,000 tokens.
/// Rates are EDITABLE locally and never leave the device.
/// Values are EXAMPLE public list prices and MUST be refreshed when vendors
/// change them — see `NotchDeck-usage-cost-tab-spec.md`.
public struct ModelPrice: Sendable, Equatable, Codable {
    public var inputUSDperMTok: Double
    public var outputUSDperMTok: Double
    public var cacheWriteUSDperMTok: Double
    public var cacheReadUSDperMTok: Double

    public init(
        inputUSDperMTok: Double,
        outputUSDperMTok: Double,
        cacheWriteUSDperMTok: Double,
        cacheReadUSDperMTok: Double
    ) {
        self.inputUSDperMTok = inputUSDperMTok
        self.outputUSDperMTok = outputUSDperMTok
        self.cacheWriteUSDperMTok = cacheWriteUSDperMTok
        self.cacheReadUSDperMTok = cacheReadUSDperMTok
    }
}

public enum PriceTable {
    /// Example public list prices (USD / 1M tokens), as of 2026-08.
    /// EDIT locally via the Settings UI; persisted as a diff over this default.
    public static let `default`: [String: ModelPrice] = [
        "claude-opus-4":     .init(inputUSDperMTok: 15,   outputUSDperMTok: 75,  cacheWriteUSDperMTok: 18.75, cacheReadUSDperMTok: 1.50),
        "claude-sonnet-4":   .init(inputUSDperMTok: 3,    outputUSDperMTok: 15,  cacheWriteUSDperMTok: 3.75,  cacheReadUSDperMTok: 0.30),
        "claude-haiku-3.5":  .init(inputUSDperMTok: 0.80, outputUSDperMTok: 4,   cacheWriteUSDperMTok: 1.00,  cacheReadUSDperMTok: 0.08),
        "claude-3.5-sonnet": .init(inputUSDperMTok: 3,    outputUSDperMTok: 15,  cacheWriteUSDperMTok: 3.75,  cacheReadUSDperMTok: 0.30),
        "claude-3.5-haiku":  .init(inputUSDperMTok: 0.80, outputUSDperMTok: 4,   cacheWriteUSDperMTok: 1.00,  cacheReadUSDperMTok: 0.08),
        "gpt-5":             .init(inputUSDperMTok: 10,   outputUSDperMTok: 30,  cacheWriteUSDperMTok: 0,     cacheReadUSDperMTok: 0),
        "gpt-5-mini":        .init(inputUSDperMTok: 1.25, outputUSDperMTok: 10,  cacheWriteUSDperMTok: 0,     cacheReadUSDperMTok: 0),
        "gpt-4o":            .init(inputUSDperMTok: 2.50, outputUSDperMTok: 10,  cacheWriteUSDperMTok: 0,     cacheReadUSDperMTok: 0),
        "o1":                .init(inputUSDperMTok: 15,   outputUSDperMTok: 60,  cacheWriteUSDperMTok: 0,     cacheReadUSDperMTok: 0),
    ]

    /// User overrides persisted in UserDefaults (key: model id), merged over `default`.
    private static let overridesKey = "notchdeck.priceTableOverrides"

    /// Effective table = `default` with user overrides applied.
    public static func load() -> [String: ModelPrice] {
        var table = `default`
        guard let data = UserDefaults.standard.data(forKey: overridesKey),
              let decoded = try? JSONDecoder().decode([String: ModelPrice].self, from: data) else {
            return table
        }
        for (k, v) in decoded { table[k] = v }
        return table
    }

    /// Persist only the diff from `default` (keeps storage small and resilient
    /// to future default-table changes).
    public static func save(_ table: [String: ModelPrice]) {
        var diff: [String: ModelPrice] = [:]
        for (k, v) in table where v != `default`[k] {
            diff[k] = v
        }
        if let data = try? JSONEncoder().encode(diff) {
            UserDefaults.standard.set(data, forKey: overridesKey)
        }
    }

    /// Estimate USD cost for a token total under a given model.
    /// Returns 0 when the model is unknown (caller should surface "unknown model").
    public static func estimate(_ totals: ClaudeUsageTotals, model: String, table: [String: ModelPrice]) -> Double {
        guard let price = table[model] else { return 0 }
        let inCost  = Double(totals.inputTokens) / 1_000_000 * price.inputUSDperMTok
        let outCost = Double(totals.outputTokens) / 1_000_000 * price.outputUSDperMTok
        let cwCost  = Double(totals.cacheCreationTokens) / 1_000_000 * price.cacheWriteUSDperMTok
        let crCost  = Double(totals.cacheReadTokens) / 1_000_000 * price.cacheReadUSDperMTok
        return inCost + outCost + cwCost + crCost
    }
}
