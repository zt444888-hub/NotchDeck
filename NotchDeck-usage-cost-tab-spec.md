# NotchDeck — "Usage & Cost"（用量 / 费用）标签页功能规格

> 目标：在现有 10 个设置页之外新增第 11 个页面 **`Usage & Cost`**，把 `codex-island` 的"配额 / 费用监控"能力吸收进来，并凭借 NotchDeck 的**本地优先 + 实时会话追踪**优势做得更强。
> 现状地基：Core 已有 `ClaudeUsageScanner`（扫 `~/.claude/projects/**/*.jsonl`，算 `last5h` / `today` / 12h sparkline，增量解析 + 按 `message.id` dedupe，纯本地零网络）。本规格在其上扩展，不重复造轮子。

---

## 1. 为什么做 / 如何超越 codex-island

| 能力 | codex-island | NotchDeck（本规格目标） |
|---|---|---|
| 覆盖的编码助手 | Claude + Codex（仅 2 个） | Claude + Codex +（架构预留 Gemini/Cursor/Kiro…） |
| 配额窗口 | 5h + 7d（Claude/Codex 各自） | 同款 5h/7d，**额外** today/30d/本年 |
| 费用估算 | 有（估算） | 有，且**本地可编辑单价表**，按模型拆分 |
| 实时性 | 仅定期拉取，**无实时控制** | 复用 AppState 实时会话流，**实时 token 计数** |
| 可视化 | 基础数字 | sparkline + 日柱状 + 模型堆叠 + **年度热力图** |
| 移动伴侣 | 无 | 已有 Apple/Buddy 伴侣（可 mirror 用量） |
| 数据出网 | 依赖各厂商 API | **零出网**，纯本地文件 |

**核心差异点**：codex-island 是"事后看板"，NotchDeck 是"实时仪表盘 + 事后审计"。我们要把 codex-island 的配额/费用叙事**完整覆盖并增强**。

---

## 2. 新增设置页接入点（不动现有结构）

现有 `SettingsPage` 枚举（`Sources/CodeIsland/SettingsView.swift:8`）与 `sidebarGroups`（:58）：

```swift
enum SettingsPage: String, Identifiable, Hashable {
    case general, behavior, appearance, mascots, sound, shortcuts
    case remote, hooks, buddy, about
    // 新增 ↓
    case usage
}
// icon / color 补一个：
case .usage: return "chart.bar.xaxis"   // SF Symbol
case .usage: return .teal
// switch 补：
case .usage: UsageCostPage()
// sidebarGroups：放进第一组（与 general 同级），或独立 Section "Insights"
```

- 本地化：在 `L10n.strings` 的 7 种语言（en/zh/zh-Hant/de/ja/ko/tr）各加 `"usage": "Usage & Cost"` / `"用量与费用"` / 等。复用现有 `l10n[page.rawValue]` 机制，无需改读取逻辑。
- 新建文件：`Sources/CodeIsland/UsageCostView.swift`，含 `UsageCostPage` 与各子图表视图。

---

## 3. 数据架构（复用 + 扩展）

### 3.1 已有可复用
- `ClaudeUsageScanner.Snapshot`：`last5h`、`today`、`hourlyOutputTokens`(12)、`scannedAt`。
- `ClaudeUsageTotals`：input/output/cacheCreate/cacheRead/messageCount + `formatTokens(_:)`。
- `ClaudeUsageScanner.scan(claudeHome:now:cache:)` 的**增量 FileCache**——直接复用，避免重读大转录。

### 3.2 新增模块（CodeIslandCore）
```
CodeIslandCore/
 ├─ ClaudeUsageScanner.swift      (已有，扩 last7d / last30d / year)
 ├─ CodexUsageScanner.swift       (新增，同构接口)
 ├─ UsageCostStore.swift          (新增，聚合 + 费用估算 + 发布)
 └─ PriceTable.swift              (新增，本地单价表，可用户编辑)
```

**CodexUsageScanner**（对齐 Claude 的接口）：
- 数据源：Codex CLI 转录路径待确认，优先探测 `~/.codex/projects/**/*.jsonl`；若 NotchDeck 已有的 `CodexAppServerClient`（`Sources/CodeIslandCore/CodexAppServerClient.swift`）已能拉到用量，则直接复用其返回结构，包装成 `ClaudeUsageTotals` 同构体 `CodexUsageTotals`。
- 同样做增量解析 + dedupe（按 Codex 的 `item.id`）。
- ⚠️ 实现前先用 `find ~ -path '*codex*' -name '*.jsonl'` 实测路径，再固化。

**UsageCostStore**（ObservableObject，@MainActor）：
- 周期性（每 60s）+ 前台激活时重扫；同时订阅 `AppState` 的**实时会话流**做即时计数（这是超越 codex-island 的关键）。
- 输出一个统一 `UsageCostSnapshot`：
  ```swift
  struct UsageCostSnapshot {
      var windows: [WindowKind: ProviderTotals]   // .last5h/.today/.last7d/.last30d/.year
      var byProvider: [Provider: ProviderTotals]   // .claude/.codex
      var byModel: [String: ModelTotals]          // "claude-opus-4" → tokens + estCost
      var yearHeatmap: [Date: Int]                 // 每日 output tokens，供年度热力图
      var liveSession: LiveSessionCounters?        // 当前会话实时计数（来自 AppState）
      var estimatedCostUSD: Double                // 本地估算总额
  }
  ```

### 3.3 费用估算（PriceTable）
- 本地 JSON/plist 存单价表：`[model: (inputUSDperMTok, outputUSDperMTok, cacheWrite, cacheRead)]`。
- 初始值用公开价目（示例，须标注"示例、可编辑、需随厂商调价更新"）：
  - claude-opus-4: $15 / $75（in/out，每 MTok）
  - claude-sonnet-4: $3 / $15
  - claude-haiku-3.5: $0.80 / $4
  - gpt-4o: $2.50 / $10
  - o1: $15 / $60
- 估算公式：`cost = (input/1e6)*inRate + (output/1e6)*outRate + cacheWrite/1e6*cwRate + cacheRead/1e6*crRate`。
- 设置页内提供"编辑单价"入口，**所有数值保留在本地 UserDefaults / 文件，绝不回传**。
- 明确 UI 文案："Estimated cost · local only · rates editable"，避免与官方账单混淆（法务安全）。

---

## 4. UI 设计（UsageCostPage）

布局（SwiftUI `List`/`Form` 内分段）：

### 4.1 顶部：配额窗口卡（对齐 codex-island 的 5h/7d）
- **Claude 5h / 7d** 与 **Codex 5h / 7d** 并排显示（codex-island 的核心卖点）。
- 显示"剩余/重置时间"进度环（基于厂商配额周期；Claude 5h 窗口从最近一次请求起算，7d 为自然周/滚动 7 天——按 `ClaudeUsageScanner` 现有 5h 逻辑扩展）。
- 超出阈值（如 5h 用量 > 80%）用 `.orange` 提示。

### 4.2 实时会话条（NotchDeck 独有）
- 复用 `AppState` 当前活跃会话，显示实时 input/output token 滚动计数 + 本次会话预估费用。
- codex-island 无此能力 → 这是差异化亮点。

### 4.3 图表区
1. **Sparkline**（复用 12h `hourlyOutputTokens`，扩展到 24h）。
2. **日柱状图**（last 30d）：用 SwiftUI `BarMark` 风格自绘（或引入轻量 Charts.framework——macOS 14 可用，零额外依赖）。
3. **模型堆叠面积/折线**（byModel）：展示各模型贡献占比。
4. **年度热力图**（yearHeatmap）：GitHub-style 方格矩阵（53 周 × 7 天），色深 = 当日 output tokens。点格显示 tooltip（日期 + tokens + 估算费用）。

### 4.4 费用汇总
- 大字显示 `estimatedCostUSD`（本月 / 本年），下方按 provider / model 拆分小字。
- "编辑单价"按钮 → 打开 `PriceTableEditor`（标准 Form）。
- 免责声明一行："Estimate only · based on local usage files · not an official bill."

### 4.5 导出
- "Export CSV"：导出 `yearHeatmap` + `byModel` 为 CSV（用现有 `DiagnosticsExporter` 同款机制，存到用户选的本地路径）。

---

## 5. 本地化 / RTL

- 新增 key：`"usage"`, `"usage_last5h"`, `"usage_last7d"`, `"usage_today"`, `"usage_month"`, `"usage_year"`, `"usage_estimated_cost"`, `"usage_edit_rates"`, `"usage_live_session"`, `"usage_export_csv"`, `"usage_estimate_disclaimer"`。
- 在 7 种语言 dict 补齐；**ar / he 文案**从 `codeisland-launch-pack.md` 的 RTL 段落取（已在上一交付物起草）。
- 图表坐标轴、进度环文案使用 `.leading`/`.trailing` 锚点；热力图列序在 RTL 下整体镜像（第 1 周在最右）。
- 数字格式化：`formatTokens` 复用；货币用 `NumberFormatter(.currency, USD)`，注意 ar/he 的阿拉伯数字形态（可保留西文数字，符合开发者工具习惯）。

---

## 6. 测试策略（对齐现有 Core 测试）

- `ClaudeUsageScannerTests` 已有增量/dedupe 用例 → 新增 `last7d`/`last30d`/`year` 窗口断言。
- 新增 `CodexUsageScannerTests`：用 fixtures（构造 2~3 个 Codex jsonl 样例）验证解析与 dedupe。
- 新增 `UsageCostStoreTests`：注入假 `ClaudeUsageTotals` + `CodexUsageTotals`，断言 `estimatedCostUSD` 计算正确（已知单价 → 已知结果）。
- 新增 `PriceTableTests`：编辑后持久化往返、非法值（负数/0）拒绝。
- UI 用 `UsageCostPage()` + 注入 `UsageCostStore` 预览（SwiftUI `#Preview`），RTL 用 `.environment(\.layoutDirection, .rightToLeft)` 验证。

---

## 7. 实施步骤（建议顺序）

1. **Core**：扩 `ClaudeUsageScanner` 增加 7d/30d/year 窗口（纯加法，向后兼容现有 `Snapshot`）。
2. **Core**：写 `CodexUsageScanner`（先 `find` 实测路径再固化），接口同构。
3. **Core**：写 `PriceTable` + `UsageCostStore`（聚合 + 估算 + 实时订阅）。
4. **UI**：`UsageCostView.swift` 的 `UsageCostPage` + 子图表；先 sparkline/柱状，再热力图。
5. **接入**：`SettingsPage` 枚举 + `sidebarGroups` + `switch` + 7 语言 key。
6. **本地化**：ar/he RTL 文案与镜像布局。
7. **测试**：补齐 Core/UI 测试，跑 `swift test`。
8. **伴侣同步**（可选）：通过已有 `AppleCompanionPublisher` 把 `UsageCostSnapshot` 推到 Buddy。

---

## 8. 范围与开放问题

- **Codex 数据源路径**：实现前必须 `find` 实测，避免假设。
- **配额"剩余"语义**：Claude 官方 5h/7d 是否对免费/订阅用户相同？NotchDeck 只能基于本地用量反推"已用"，无法获知厂商硬限额 → UI 显示"已用 X（近 5h）"，不宣称"剩余 Y"，除非接入官方配额 API（超出本地优先原则，本期不做）。
- **是否纳入 Gemini/Cursor/Kiro 等**：架构预留 `byProvider`，但本期仅 Claude+Codex（与 codex-island 对齐，先打赢这一仗）。
- **费用精度**：纯估算，必须在 UI 与隐私文案中明确"非官方账单"，规避误导与合规风险。
