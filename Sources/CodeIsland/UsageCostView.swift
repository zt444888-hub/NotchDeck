import SwiftUI
import AppKit
import Combine

// MARK: - Store

/// Periodically re-scans local Claude + Codex transcripts and publishes a
/// unified usage/cost snapshot. Independent of `AppState` (which drives the
/// notch footer) to keep this tab decoupled and testable.
@MainActor
final class UsageCostStore: ObservableObject {
    @Published private(set) var snapshot: UsageCostSnapshot = UsageCostSnapshot()
    @Published private(set) var scannedAt: Date?
    @Published private(set) var isEmpty: Bool = true

    /// Primary model billed per provider. v1 attributes a provider's whole
    /// trailing-year total to this model (we don't parse per-message model yet).
    private let modelForProvider: [Provider: String] = [.claude: "claude-sonnet-4", .codex: "gpt-5"]

    private var claudeCache = ClaudeUsageScanner.FileCache()
    private var timer: Timer?

    func start() {
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func rescan() {
        let claude = ClaudeUsageScanner.scan(cache: &claudeCache)
        let codex = CodexUsageScanner.scan()
        let table = PriceTable.load()
        let snap = UsageCostAggregator.aggregate(
            claude: claude,
            codex: codex,
            priceTable: table,
            modelForProvider: modelForProvider
        )
        self.snapshot = snap
        self.scannedAt = claude.scannedAt
        self.isEmpty = claude.isEmpty && codex.isEmpty
    }
}

// MARK: - View

struct UsageCostPage: View {
    @ObservedObject private var l10n = L10n.shared
    @StateObject private var store = UsageCostStore()

    private let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if store.isEmpty {
                    emptyState
                } else {
                    quotaSection
                    costSection
                    breakdownSection
                    chartsSection
                    exportRow
                    disclaimer
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            Text(l10n["usage"])
                .font(.system(size: 22, weight: .bold))
            Spacer()
            if let at = store.scannedAt {
                Text("\(l10n["usage_scanned_at"]) \(timeFormatter.string(from: at))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Button {
                store.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(l10n["usage_refresh"])
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(l10n["usage_empty"])
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Quota windows (per provider)

    private var quotaSection: some View {
        SectionView(title: l10n["usage_quota"]) {
            HStack(spacing: 14) {
                providerQuotaCard(.claude)
                providerQuotaCard(.codex)
            }
        }
    }

    private func providerQuotaCard(_ provider: Provider) -> some View {
        let windows = store.snapshot.byProviderWindows[provider] ?? [:]
        let totals = store.snapshot.byProvider[provider] ?? ClaudeUsageTotals()
        let model = provider == .claude ? "claude-sonnet-4" : "gpt-5"
        let cost = PriceTable.estimate(totals, model: model, table: PriceTable.load())
        return VStack(alignment: .leading, spacing: 8) {
            Label(provider == .claude ? "Claude" : "Codex",
                  systemImage: provider == .claude ? "ellipsis.curlybraces" : "cpu")
                .font(.system(size: 13, weight: .semibold))
            miniWindow(l10n["usage_last5h"], windows[.last5h] ?? ClaudeUsageTotals())
            miniWindow(l10n["usage_last7d"], windows[.last7d] ?? ClaudeUsageTotals())
            miniWindow(l10n["usage_last30d"], windows[.last30d] ?? ClaudeUsageTotals())
            HStack {
                Text(l10n["usage_estimated_cost"])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(currencyFormatter.string(from: NSNumber(value: cost)) ?? "$\(cost)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func miniWindow(_ title: String, _ totals: ClaudeUsageTotals) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text("↑\(ClaudeUsageScanner.formatTokens(totals.inputTokens + totals.cacheCreationTokens)) ↓\(ClaudeUsageScanner.formatTokens(totals.outputTokens))")
                .font(.system(size: 12, design: .monospaced))
        }
    }

    // MARK: Cost summary

    private var costSection: some View {
        SectionView(title: l10n["usage_estimated_cost"]) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(currencyFormatter.string(from: NSNumber(value: store.snapshot.estimatedCostUSD)) ?? "$\(store.snapshot.estimatedCostUSD)")
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                Text("· \(l10n["usage_year"])")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    // MARK: Per-model breakdown

    private var breakdownSection: some View {
        SectionView(title: l10n["usage_per_model"]) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.snapshot.byModel.keys.sorted(), id: \.self) { model in
                    if let totals = store.snapshot.byModel[model] {
                        HStack {
                            Text(model).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text("↑\(ClaudeUsageScanner.formatTokens(totals.inputTokens + totals.cacheCreationTokens)) ↓\(ClaudeUsageScanner.formatTokens(totals.outputTokens))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    // MARK: Charts (bar + heatmap)

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionView(title: l10n["usage_30d"]) {
                barChart
                    .frame(height: 120)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
            }
            SectionView(title: l10n["usage_year"]) {
                heatmap
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private var barChart: some View {
        let days = last30Days()
        let maxV = max(1, days.map { $0.1 }.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, v in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(height: CGFloat(v) / CGFloat(maxV) * 100)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var heatmap: some View {
        let grid = heatmapGrid()
        let maxV = max(1, grid.flatMap { $0.compactMap { $1 } }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                            Rectangle()
                                .fill(cellColor(cell.1, max: maxV))
                                .frame(width: 11, height: 11)
                                .cornerRadius(2)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(l10n["usage_less"]).font(.system(size: 10)).foregroundStyle(.tertiary)
                ForEach(0..<5) { i in
                    Rectangle().fill(stepColor(Double(i) / 4)).frame(width: 11, height: 11).cornerRadius(2)
                }
                Text(l10n["usage_more"]).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Export + disclaimer

    private var exportRow: some View {
        Button {
            exportCSV()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                Text(l10n["usage_export_csv"])
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
    }

    private var disclaimer: some View {
        Text(l10n["usage_estimate_disclaimer"])
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func last30Days() -> [(Date, Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (d, store.snapshot.yearHeatmap[d] ?? 0)
        }
    }

    private func heatmapGrid() -> [[(Date, Int?)]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -364, to: today) else { return [] }
        var grid: [[(Date, Int?)]] = []
        var week: [(Date, Int?)] = []
        var cursor = start
        while cursor <= today {
            week.append((cursor, store.snapshot.yearHeatmap[cursor]))
            if week.count == 7 { grid.append(week); week = [] }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        if !week.isEmpty { grid.append(week) }
        return grid
    }

    private func cellColor(_ value: Int?, max: Int) -> Color {
        guard let v = value, v > 0 else { return Color(nsColor: .controlBackgroundColor) }
        return stepColor(Double(v) / Double(max))
    }

    private func stepColor(_ t: Double) -> Color {
        let clamped = min(1, max(0, t))
        return Color(hue: 0.52, saturation: 0.55, brightness: 0.55 + 0.4 * clamped)
    }

    private func exportCSV() {
        var csv = "date,output_tokens\n"
        for (d, v) in store.snapshot.yearHeatmap.sorted(by: { $0.key < $1.key }) {
            csv += "\(isoDate(d)),\(v)\n"
        }
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let file = dir.appendingPathComponent("NotchDeck-usage-\(isoDate(Date())).csv")
        try? csv.write(to: file, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func isoDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - Shared section chrome

private struct SectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
