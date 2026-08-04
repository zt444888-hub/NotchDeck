import Foundation

/// Token usage aggregated from local Codex (OpenAI) transcripts
/// (`~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`).
/// Local-first, no provider API calls — same philosophy as `ClaudeUsageScanner`.
///
/// Wire format (one JSON object per line):
/// - `type == "event_msg"` with `payload.type == "token_count"` carries the
///   accounting for a turn.
/// - `payload.info.total_token_usage` is the **cumulative** total for the whole
///   session and grows monotonically within a file (verified against real
///   transcripts: 103 samples, 11,772 → 12,864,849).
/// - `payload.info.last_token_usage` is a *rolling* delta and **must not** be
///   summed across turns — doing so over-counts by ~4.6× vs the real total.
///
/// Therefore, per session file we take the `token_count` event with the greatest
/// `total_token_usage.total_tokens` (i.e. the final cumulative total) and
/// attribute that whole-session total to the event's timestamp. This yields the
/// correct magnitude and avoids double counting. A session active across
/// multiple days is attributed to its final activity time (acceptable for an
/// estimate dashboard).
public enum CodexUsageScanner {
    /// Sparkline resolution: one bucket per hour, oldest first (parity with Claude).
    public static let sparklineHours = 12

    public struct Snapshot: Equatable, Sendable {
        public let last5h: ClaudeUsageTotals
        public let today: ClaudeUsageTotals
        /// Trailing 7-day and 30-day totals (rolling windows).
        public let last7d: ClaudeUsageTotals
        public let last30d: ClaudeUsageTotals
        /// Full token totals for the trailing ~365 days (superset of all other
        /// windows). Used as the cost-estimation basis and the `.year` window.
        public let yearTotals: ClaudeUsageTotals
        /// Per-day output-token totals for the trailing ~365 days, keyed by the
        /// day's midnight `Date`. Drives the year heatmap.
        public let year: [Date: Int]
        /// Output tokens per hour for the trailing `sparklineHours` hours.
        public let hourlyOutputTokens: [Int]
        public let scannedAt: Date

        public init(
            last5h: ClaudeUsageTotals,
            today: ClaudeUsageTotals,
            hourlyOutputTokens: [Int],
            scannedAt: Date,
            last7d: ClaudeUsageTotals = ClaudeUsageTotals(),
            last30d: ClaudeUsageTotals = ClaudeUsageTotals(),
            yearTotals: ClaudeUsageTotals = ClaudeUsageTotals(),
            year: [Date: Int] = [:]
        ) {
            self.last5h = last5h
            self.today = today
            self.hourlyOutputTokens = hourlyOutputTokens
            self.scannedAt = scannedAt
            self.last7d = last7d
            self.last30d = last30d
            self.yearTotals = yearTotals
            self.year = year
        }

        /// True when no tokens were observed in any window (used by the UI to
        /// render the empty state). Mirrors `ClaudeUsageTotals.isEmpty`.
        public var isEmpty: Bool {
            last5h.isEmpty && today.isEmpty && last7d.isEmpty
                && last30d.isEmpty && yearTotals.isEmpty && year.isEmpty
        }
    }

    /// Scan the default Codex sessions directory.
    public static func scan(codexHome: String = defaultSessionsRoot(), now: Date = Date()) -> Snapshot {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let midnight = Calendar.current.startOfDay(for: now)
        let sparklineStart = now.addingTimeInterval(-Double(sparklineHours) * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86400)
        let yearStart = Calendar.current.startOfDay(for: now.addingTimeInterval(-365 * 86400))
        let cutoff = min(fiveHoursAgo, midnight, sparklineStart, yearStart)

        var last5h = ClaudeUsageTotals()
        var today = ClaudeUsageTotals()
        var last7d = ClaudeUsageTotals()
        var last30d = ClaudeUsageTotals()
        var yearTotals = ClaudeUsageTotals()
        var year: [Date: Int] = [:]
        var hourly = [Int](repeating: 0, count: sparklineHours)

        let fm = FileManager.default
        guard let subs = try? fm.subpathsOfDirectory(atPath: codexHome) else {
            return Snapshot(last5h: last5h, today: today, hourlyOutputTokens: hourly, scannedAt: now)
        }

        for rel in subs where rel.hasSuffix(".jsonl") {
            let path = (codexHome as NSString).appendingPathComponent(rel)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime >= cutoff else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let text = String(data: data, encoding: .utf8) else { continue }

            // Per session file: keep the token_count event with the greatest
            // cumulative total_token_usage (the session's true final total).
            var best: (ts: Date, totals: ClaudeUsageTotals, total: Int)?
            for line in text.split(separator: "\n") {
                guard let parsed = parseTokenCount(String(line)) else { continue }
                if let current = best {
                    if parsed.total >= current.total { best = parsed }
                } else {
                    best = parsed
                }
            }
            guard let best else { continue }

            let ts = best.ts
            let u = best.totals
            if ts >= fiveHoursAgo { last5h.add(u) }
            if ts >= midnight { today.add(u) }
            if ts >= sevenDaysAgo { last7d.add(u) }
            if ts >= thirtyDaysAgo { last30d.add(u) }
            if ts >= yearStart {
                yearTotals.add(u)
                let dayKey = Calendar.current.startOfDay(for: ts)
                year[dayKey, default: 0] += u.outputTokens
            }
            let hoursAgo = Int(now.timeIntervalSince(ts) / 3600)
            if hoursAgo >= 0 && hoursAgo < sparklineHours {
                hourly[sparklineHours - 1 - hoursAgo] += u.outputTokens
            }
        }

        return Snapshot(
            last5h: last5h,
            today: today,
            hourlyOutputTokens: hourly,
            scannedAt: now,
            last7d: last7d,
            last30d: last30d,
            yearTotals: yearTotals,
            year: year
        )
    }

    // MARK: - Parsing

    /// `(timestamp, unified totals, cumulative total used for max-picking)`.
    private static func parseTokenCount(_ line: String) -> (ts: Date, totals: ClaudeUsageTotals, total: Int)? {
        guard line.contains("\"token_count\""),
              (line.contains("\"total_token_usage\"") || line.contains("\"last_token_usage\"")) else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "event_msg",
              let tsRaw = obj["timestamp"] as? String,
              let ts = ClaudeUsageScanner.parseISO8601(tsRaw),
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any]
        else { return nil }

        // Prefer the cumulative total; fall back to the rolling delta only if the
        // cumulative figure is absent (defensive — real transcripts always have it).
        let usageDict: [String: Any]? = (info["total_token_usage"] as? [String: Any])
            ?? (info["last_token_usage"] as? [String: Any])
        guard let u = usageDict else { return nil }

        var totals = ClaudeUsageTotals()
        totals.inputTokens = u["input_tokens"] as? Int ?? 0
        // Reasoning tokens are billed as output; fold them in for cost parity.
        let out = (u["output_tokens"] as? Int ?? 0) + (u["reasoning_output_tokens"] as? Int ?? 0)
        totals.outputTokens = out
        totals.cacheReadTokens = u["cached_input_tokens"] as? Int ?? 0
        totals.cacheCreationTokens = u["cache_write_input_tokens"] as? Int ?? 0
        totals.messageCount = 1

        let total = u["total_tokens"] as? Int
            ?? (totals.inputTokens + totals.outputTokens + totals.cacheReadTokens + totals.cacheCreationTokens)
        return (ts: ts, totals: totals, total: total)
    }

    public static func defaultSessionsRoot() -> String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".codex/sessions")
    }
}
