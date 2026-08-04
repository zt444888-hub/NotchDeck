import XCTest
@testable import CodeIslandCore

final class UsageCostAggregatorTests: XCTestCase {
    private func claudeSnapshot(last5h: ClaudeUsageTotals,
                                yearTotals: ClaudeUsageTotals) -> ClaudeUsageScanner.Snapshot {
        ClaudeUsageScanner.Snapshot(
            last5h: last5h,
            today: last5h,
            hourlyOutputTokens: [0, 0, 0],
            scannedAt: Date(),
            last7d: last5h,
            last30d: last5h,
            yearTotals: yearTotals,
            year: [:]
        )
    }

    private func codexSnapshot(last5h: ClaudeUsageTotals,
                               yearTotals: ClaudeUsageTotals) -> CodexUsageScanner.Snapshot {
        CodexUsageScanner.Snapshot(
            last5h: last5h,
            today: last5h,
            hourlyOutputTokens: [0, 0, 0],
            scannedAt: Date(),
            last7d: last5h,
            last30d: last5h,
            yearTotals: yearTotals,
            year: [:]
        )
    }

    private var table: [String: ModelPrice] {
        [
            "claude-sonnet-4": .init(inputUSDperMTok: 3, outputUSDperMTok: 15,
                                    cacheWriteUSDperMTok: 0, cacheReadUSDperMTok: 0),
            "gpt-5": .init(inputUSDperMTok: 10, outputUSDperMTok: 30,
                          cacheWriteUSDperMTok: 0, cacheReadUSDperMTok: 0)
        ]
    }

    func testAggregateMergesWindowsAndProviders() {
        var claude5h = ClaudeUsageTotals(); claude5h.inputTokens = 1_000_000; claude5h.outputTokens = 2_000_000
        var claudeYear = ClaudeUsageTotals(); claudeYear.inputTokens = 5_000_000; claudeYear.outputTokens = 10_000_000
        var codex5h = ClaudeUsageTotals(); codex5h.inputTokens = 500_000; codex5h.outputTokens = 1_000_000
        var codexYear = ClaudeUsageTotals(); codexYear.inputTokens = 2_000_000; codexYear.outputTokens = 4_000_000

        let snap = UsageCostAggregator.aggregate(
            claude: claudeSnapshot(last5h: claude5h, yearTotals: claudeYear),
            codex: codexSnapshot(last5h: codex5h, yearTotals: codexYear),
            priceTable: table,
            modelForProvider: [.claude: "claude-sonnet-4", .codex: "gpt-5"]
        )

        // Combined 5h window = claude + codex
        XCTAssertEqual(snap.windows[.last5h]?.inputTokens, 1_500_000)
        XCTAssertEqual(snap.windows[.last5h]?.outputTokens, 3_000_000)

        // Per-provider totals
        XCTAssertEqual(snap.byProvider[.claude]?.inputTokens, 5_000_000)
        XCTAssertEqual(snap.byProvider[.codex]?.inputTokens, 2_000_000)

        // Per-provider windows (the quota cards)
        XCTAssertEqual(snap.byProviderWindows[.claude]?[.last5h]?.inputTokens, 1_000_000)
        XCTAssertEqual(snap.byProviderWindows[.codex]?[.last5h]?.inputTokens, 500_000)

        // By-model attribution (one model per provider in v1)
        XCTAssertEqual(snap.byModel["claude-sonnet-4"]?.inputTokens, 5_000_000)
        XCTAssertEqual(snap.byModel["gpt-5"]?.inputTokens, 2_000_000)

        // Cost = claude(5M in *3 + 10M out *15) + codex(2M in *10 + 4M out *30)
        //      = 15 + 150 + 20 + 120 = 305
        XCTAssertEqual(snap.estimatedCostUSD, 305, accuracy: 1e-9)
    }

    func testAggregateNilProvidersAreSafe() {
        let snap = UsageCostAggregator.aggregate(
            claude: nil, codex: nil,
            priceTable: table,
            modelForProvider: [.claude: "claude-sonnet-4", .codex: "gpt-5"]
        )
        XCTAssertEqual(snap.estimatedCostUSD, 0, accuracy: 1e-9)
        XCTAssertNil(snap.windows[.last5h])
        XCTAssertTrue(snap.byProvider.isEmpty)
    }
}
