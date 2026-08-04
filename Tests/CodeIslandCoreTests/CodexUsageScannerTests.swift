import XCTest
@testable import CodeIslandCore

final class CodexUsageScannerTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "codex-usage-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: root + "/sessions/2026/07/20", withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// A `token_count` event line. `total` is the cumulative session total;
    /// `last` is the rolling delta (intentionally different to prove we DON'T
    /// sum `last_token_usage`).
    private func tokenCountLine(at date: Date, total: Int, last: Int) -> String {
        let totalUsage: [String: Any] = [
            "input_tokens": total,
            "output_tokens": total / 2,
            "cached_input_tokens": total / 10,
            "cache_write_input_tokens": total / 20,
            "reasoning_output_tokens": total / 20,
            "total_tokens": total
        ]
        let lastUsage: [String: Any] = [
            "input_tokens": last,
            "output_tokens": last / 2,
            "cached_input_tokens": last / 10,
            "cache_write_input_tokens": last / 20,
            "reasoning_output_tokens": last / 20,
            "total_tokens": last
        ]
        let payload: [String: Any] = [
            "type": "token_count",
            "info": ["total_token_usage": totalUsage, "last_token_usage": lastUsage]
        ]
        let obj: [String: Any] = [
            "timestamp": iso(date),
            "type": "event_msg",
            "payload": payload
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// Build a session file with two token_count events: a small cumulative one
    /// and a large cumulative one. The scanner must pick the LARGE one (max
    /// total_token_usage) and must NOT sum last_token_usage (which would over-count).
    private func writeSessionFile(name: String, lines: [String]) throws {
        let path = root + "/sessions/2026/07/20/" + name
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testPicksMaxCumulativeTotalNotSumOfDeltas() throws {
        let now = Date()
        let early = now.addingTimeInterval(-60)
        // Event A: cumulative total = 1000, but its rolling delta (last) = 100.
        // Event B: cumulative total = 5000, rolling delta = 300.
        try writeSessionFile(
            name: "rollout-pickmax.jsonl",
            lines: [
                tokenCountLine(at: early, total: 1000, last: 100),
                tokenCountLine(at: now, total: 5000, last: 300)
            ]
        )

        let snap = CodexUsageScanner.scan(codexHome: root, now: now)

        // Must equal the MAX cumulative event (5000/2500/500/250), NOT the sum
        // of deltas (100+300=400 input) which would wrongly over-count.
        XCTAssertEqual(snap.last5h.inputTokens, 5000)
        XCTAssertEqual(snap.last5h.outputTokens, 2500 + 250) // output + reasoning
        XCTAssertEqual(snap.last5h.cacheReadTokens, 500)
        XCTAssertEqual(snap.last5h.cacheCreationTokens, 250)

        // Year total matches the chosen session total.
        XCTAssertEqual(snap.yearTotals.inputTokens, 5000)

        // Heatmap: that day carries the session's output tokens.
        let dayKey = Calendar.current.startOfDay(for: now)
        XCTAssertEqual(snap.year[dayKey], 2500 + 250)

        XCTAssertFalse(snap.isEmpty)
    }

    func testEmptyWhenNoSessions() {
        let snap = CodexUsageScanner.scan(codexHome: root, now: Date())
        XCTAssertTrue(snap.isEmpty)
        XCTAssertEqual(snap.last5h.inputTokens, 0)
    }

    /// A session whose final activity is 10 days ago must land in 7d/30d but
    /// NOT in 5h.
    func testWindowBucketingByTimestamp() throws {
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86400)
        try writeSessionFile(
            name: "rollout-window.jsonl",
            lines: [tokenCountLine(at: tenDaysAgo, total: 800, last: 800)]
        )
        let snap = CodexUsageScanner.scan(codexHome: root, now: now)
        XCTAssertEqual(snap.last7d.inputTokens, 800)
        XCTAssertEqual(snap.last30d.inputTokens, 800)
        XCTAssertEqual(snap.last5h.inputTokens, 0) // 10d ago is outside 5h
    }
}
