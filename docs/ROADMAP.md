# NotchDeck Roadmap

> 维护：2026-08-06 更新。优先级按产品价值 × 成本排序。
>
> **产品定位（用户确认）**：核心 = **手机联动，远距离操控电脑上的 AI 对话**。
> 刘海面板是 Mac 端实时展示（辅助）；手机远程对话是主入口。

## 已发布

- **v1.1.8**：MCP Server P0-P2（设置页、事件去重、协议协商、MCP 徽标、端口回退）、Windsurf hooks、TRAE IDE hooks 修复
- **v1.1.9**：MCP 全功能 + TRAE Work 自动注入（mcp.json + skill + user_rules）+ 45s idle 兜底 + 安装验证

## 近期收尾（本周）

1. **手机端 BLE 链路收尾**：真机连接已通（扫描 → 连接 → 状态同步验证中）；Live Activity/StandBy/Watch 真机验证
2. **Product Hunt 首发**（周四 23:00 窗口）：物料已备（docs/product-hunt-launch.md + 演示 GIF）
3. 补推 GitHub 网络阻塞的提交

## v1.2.0：远程 AI 对话（核心功能，Pro 付费）—— P0

**需求（用户确认的核心）**：人在外面，手机远距离操控电脑上的 AI 对话——发消息、看回复、继续多轮。

**形态边界（已校准）**：NotchDeck 托管会话（手机 ↔ Mac 上的 headless agent 多轮对话），**不是**接管用户桌面上已开的 TUI 窗口（agent 无注入接口，不可行）。

**架构**（CloudKit 私有库，双端共享基建）：
- 容器：`iCloud.com.notchdeck`（双端 entitlement + 后台创建）
- 记录类型：
  - `RemoteConversation`：sessionId / messages[] / status / updatedAt（iPhone 读写，Mac 订阅执行）
  - `CompanionState`（状态快照，Mac 写 / iPhone 订阅推送）
- Mac 端**会话管理器**：headless agent 多轮（`claude -p --resume` / `codex exec`，自维护 context），串行队列，消息分块回写（流式，延迟容忍秒级）
- 通道：CKSubscription + 远程通知 + 30s 轮询兜底
- 安全：Mac「允许远程执行」开关默认关；私有数据库开发者不可见

**工程量**：4-6 个工作日
| 项 | 估时 |
|----|------|
| 双端 iCloud capability + 容器/schema | 0.5 天 |
| Mac：会话管理器（CloudKit 订阅 + headless 多轮 + 流式回写） | 2-2.5 天 |
| iPhone：远程对话 UI（会话列表 + 消息流 + 输入） | 1.5-2 天 |
| 联调（弱网/推送延迟/多会话队列） | 1 天 |

**定价**：Pro 功能（与"无限工具/历史统计"等打包）

**隐私表述调整**：README/PH 的"本地处理、无云" → "本地处理；可选 iCloud 同步（数据只进你的 iCloud，开发者不可见）"

## 远期

- **Windows 客户端**（hooks 层跨平台化 + Tauri/Electron + 任务栏形态）——市场最大（SO 2025：Windows 专业 49.5% vs macOS 32.9%），差异化弱于刘海，需产品重定位
- **局域网模式**（同一 Wi-Fi 手机看状态，零后端）——低成本补充
- **变现**：open-core（核心 MIT 开源 + Pro 闭源付费：远程对话 / 无限工具 / UsageCost 统计 / 云同步 / 主题）
