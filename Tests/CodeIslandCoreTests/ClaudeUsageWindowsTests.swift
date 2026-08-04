import XCTest
@testable import CodeIslandCore

final class ClaudeUsageWindowsTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "claude-windows-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home + "/projects/p1", withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func assistantLine(id: String, at date: Date, input: Int, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(iso(date))","message":{"id":"\(id)","role":"assistant","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    private func writeProject(_ lines: [String]) throws {
        let path = home + "/projects/p1/session.jsonl"
        // Trailing newline so the scanner's partial-line guard consumes every
        // line (a real complete file ends with a newline; the scanner only
        // defers a *partial* trailing line that's mid-append).
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testWindowsPartitionByAge() throws {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
        let twentyDaysAgo = now.addingTimeInterval(-20 * 86400)
        let fourHundredDaysAgo = now.addingTimeInterval(-400 * 86400)

        try writeProject([
            assistantLine(id: "a", at: oneHourAgo, input: 100, output: 200),
            assistantLine(id: "b", at: threeDaysAgo, input: 1000, output: 2000),
            assistantLine(id: "c", at: twentyDaysAgo, input: 10_000, output: 20_000),
            assistantLine(id: "d", at: fourHundredDaysAgo, input: 100_000, output: 200_000)
        ])

        let snap = ClaudeUsageScanner.scan(claudeHome: home, now: now)

        // 5h: only the 1h-ago line.
        XCTAssertEqual(snap.last5h.inputTokens, 100)
        // 7d: 1h + 3d ago.
        XCTAssertEqual(snap.last7d.inputTokens, 1100)
        // 30d: 1h + 3d + 20d ago (20d < 30d).
        XCTAssertEqual(snap.last30d.inputTokens, 11_100)
        // year: excludes the 400d-ago line (beyond the 365d cutoff).
        XCTAssertEqual(snap.yearTotals.inputTokens, 11_100)
        XCTAssertEqual(snap.yearTotals.outputTokens, 22_200)

        // Heatmap: the 20d-ago day carries its output tokens.
        let day20 = Calendar.current.startOfDay(for: twentyDaysAgo)
        XCTAssertEqual(snap.year[day20], 20_000)
        // The 400d-ago day is absent from the heatmap.
        let day400 = Calendar.current.startOfDay(for: fourHundredDaysAgo)
        XCTAssertNil(snap.year[day400])
    }

    func testYearHeatmapAggregatesPerDay() throws {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        try writeProject([
            assistantLine(id: "a", at: today.addingTimeInterval(3600), input: 10, output: 20),
            assistantLine(id: "b", at: today.addingTimeInterval(7200), input: 30, output: 40),
            assistantLine(id: "c", at: yesterday.addingTimeInterval(3600), input: 100, output: 200)
        ])
        let snap = ClaudeUsageScanner.scan(claudeHome: home, now: now)
        XCTAssertEqual(snap.year[today], 60)      // 20 + 40
        XCTAssertEqual(snap.year[yesterday], 200)
    }
}
