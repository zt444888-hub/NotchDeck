import Foundation

/// A coding assistant provider whose local transcripts we scan.
public enum Provider: String, CaseIterable, Sendable {
    case claude
    case codex
}

/// The aggregation windows exposed to the UI.
public enum WindowKind: String, CaseIterable, Sendable {
    case last5h
    case today
    case last7d
    case last30d
    case year
}

/// Unified, provider-agnostic usage + cost snapshot for the UI.
/// All token totals are additive across providers for the `windows` view;
/// `byProvider` / `byModel` break them down; `estimatedCostUSD` is derived from
/// each provider's trailing-year total billed under its configured model.
public struct UsageCostSnapshot: Equatable, Sendable {
    public var windows: [WindowKind: ClaudeUsageTotals]
    public var byProvider: [Provider: ClaudeUsageTotals]
    /// Per-provider windowed totals — this is what the quota cards surface
    /// (e.g. Claude 5h / Codex 7d), the core differentiator vs codex-island.
    public var byProviderWindows: [Provider: [WindowKind: ClaudeUsageTotals]]
    /// Model-keyed totals. v1 attributes a provider's whole total to its
    /// configured primary model (we don't parse per-message model yet).
    public var byModel: [String: ClaudeUsageTotals]
    /// Per-day output-token totals for the trailing ~365 days (heatmap source).
    public var yearHeatmap: [Date: Int]
    public var estimatedCostUSD: Double

    public init(
        windows: [WindowKind: ClaudeUsageTotals] = [:],
        byProvider: [Provider: ClaudeUsageTotals] = [:],
        byProviderWindows: [Provider: [WindowKind: ClaudeUsageTotals]] = [:],
        byModel: [String: ClaudeUsageTotals] = [:],
        yearHeatmap: [Date: Int] = [:],
        estimatedCostUSD: Double = 0
    ) {
        self.windows = windows
        self.byProvider = byProvider
        self.byProviderWindows = byProviderWindows
        self.byModel = byModel
        self.yearHeatmap = yearHeatmap
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public enum UsageCostAggregator {
    /// Merge Claude + Codex snapshots into a UI-ready snapshot.
    /// - `modelForProvider`: which model id to bill each provider's totals under.
    ///   Since we don't yet parse per-message model, a provider's entire trailing
    ///   year of usage is attributed to this single model.
    public static func aggregate(
        claude: ClaudeUsageScanner.Snapshot?,
        codex: CodexUsageScanner.Snapshot?,
        priceTable: [String: ModelPrice],
        modelForProvider: [Provider: String]
    ) -> UsageCostSnapshot {
        var windows: [WindowKind: ClaudeUsageTotals] = [:]
        var byProvider: [Provider: ClaudeUsageTotals] = [:]
        var byProviderWindows: [Provider: [WindowKind: ClaudeUsageTotals]] = [:]
        var byModel: [String: ClaudeUsageTotals] = [:]
        var yearHeatmap: [Date: Int] = [:]
        var cost: Double = 0

        func accumulate(_ dict: inout [Provider: [WindowKind: ClaudeUsageTotals]],
                        _ p: Provider, _ k: WindowKind, _ t: ClaudeUsageTotals) {
            var pw = dict[p] ?? [:]
            var w = pw[k] ?? ClaudeUsageTotals()
            w.add(t)
            pw[k] = w
            dict[p] = pw
        }

        func fold(_ totals: ClaudeUsageTotals, provider: Provider, model: String?) {
            byProvider[provider, default: ClaudeUsageTotals()].add(totals)
            if let model {
                byModel[model, default: ClaudeUsageTotals()].add(totals)
                cost += PriceTable.estimate(totals, model: model, table: priceTable)
            }
        }

        func merge(_ base: ClaudeUsageTotals?, _ add: ClaudeUsageTotals) -> ClaudeUsageTotals {
            var r = base ?? ClaudeUsageTotals()
            r.add(add)
            return r
        }

        if let c = claude {
            windows[.last5h] = merge(windows[.last5h], c.last5h)
            windows[.today]  = merge(windows[.today], c.today)
            windows[.last7d] = merge(windows[.last7d], c.last7d)
            windows[.last30d] = merge(windows[.last30d], c.last30d)
            windows[.year]   = merge(windows[.year], c.yearTotals)
            for (day, v) in c.year { yearHeatmap[day, default: 0] += v }
            accumulate(&byProviderWindows, .claude, .last5h, c.last5h)
            accumulate(&byProviderWindows, .claude, .today, c.today)
            accumulate(&byProviderWindows, .claude, .last7d, c.last7d)
            accumulate(&byProviderWindows, .claude, .last30d, c.last30d)
            accumulate(&byProviderWindows, .claude, .year, c.yearTotals)
            fold(c.yearTotals, provider: .claude, model: modelForProvider[.claude])
        }
        if let x = codex {
            windows[.last5h] = merge(windows[.last5h], x.last5h)
            windows[.today]  = merge(windows[.today], x.today)
            windows[.last7d] = merge(windows[.last7d], x.last7d)
            windows[.last30d] = merge(windows[.last30d], x.last30d)
            windows[.year]   = merge(windows[.year], x.yearTotals)
            for (day, v) in x.year { yearHeatmap[day, default: 0] += v }
            accumulate(&byProviderWindows, .codex, .last5h, x.last5h)
            accumulate(&byProviderWindows, .codex, .today, x.today)
            accumulate(&byProviderWindows, .codex, .last7d, x.last7d)
            accumulate(&byProviderWindows, .codex, .last30d, x.last30d)
            accumulate(&byProviderWindows, .codex, .year, x.yearTotals)
            fold(x.yearTotals, provider: .codex, model: modelForProvider[.codex])
        }

        return UsageCostSnapshot(
            windows: windows,
            byProvider: byProvider,
            byProviderWindows: byProviderWindows,
            byModel: byModel,
            yearHeatmap: yearHeatmap,
            estimatedCostUSD: cost
        )
    }
}
