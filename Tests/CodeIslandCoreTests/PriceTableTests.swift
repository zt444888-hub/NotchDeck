import XCTest
@testable import CodeIslandCore

final class PriceTableTests: XCTestCase {
    private let sample: [String: ModelPrice] = [
        "claude-sonnet-4": .init(
            inputUSDperMTok: 3, outputUSDperMTok: 15,
            cacheWriteUSDperMTok: 3.75, cacheReadUSDperMTok: 0.30)
    ]

    func testEstimateBasic() {
        var t = ClaudeUsageTotals()
        t.inputTokens = 1_000_000      // $3
        t.outputTokens = 1_000_000     // $15
        t.cacheCreationTokens = 1_000_000 // $3.75
        t.cacheReadTokens = 1_000_000   // $0.30
        let cost = PriceTable.estimate(t, model: "claude-sonnet-4", table: sample)
        XCTAssertEqual(cost, 3 + 15 + 3.75 + 0.30, accuracy: 1e-9)
    }

    func testEstimateUnknownModelIsZero() {
        var t = ClaudeUsageTotals()
        t.inputTokens = 1_000_000
        let cost = PriceTable.estimate(t, model: "does-not-exist", table: sample)
        XCTAssertEqual(cost, 0, accuracy: 1e-9)
    }

    func testEstimateIgnoresCacheWhenZeroRated() {
        // gpt-4o has zero cache rates; cache tokens should not add cost.
        let table = ["gpt-4o": ModelPrice(
            inputUSDperMTok: 2.5, outputUSDperMTok: 10,
            cacheWriteUSDperMTok: 0, cacheReadUSDperMTok: 0)]
        var t = ClaudeUsageTotals()
        t.inputTokens = 1_000_000      // $2.50
        t.outputTokens = 1_000_000     // $10
        t.cacheCreationTokens = 5_000_000
        t.cacheReadTokens = 5_000_000
        let cost = PriceTable.estimate(t, model: "gpt-4o", table: table)
        XCTAssertEqual(cost, 12.5, accuracy: 1e-9)
    }

    func testDefaultTableHasKnownModels() {
        XCTAssertNotNil(PriceTable.default["claude-opus-4"])
        XCTAssertNotNil(PriceTable.default["claude-sonnet-4"])
        XCTAssertNotNil(PriceTable.default["gpt-5"])
    }
}
