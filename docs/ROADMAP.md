# NotchDeck Roadmap

> 维护：2026-08-06 更新。优先级按产品价值 × 成本排序。
>
> **产品定位（用户确认）**：核心 = **手机联动，远距离操控电脑上的 AI 对话**。
> 刘海面板是 Mac 端实时展示（辅助）；手机远程对话是主入口。
>
> **发布节奏（用户决定）**：**先完成 v1.2.0（远程 AI 对话端到端跑通），再 PH 首发**
> ——首发带杀手级功能，冲击力最大化。PH 物料已备（docs/product-hunt-launch.md + 演示 GIF），
> 首发前主视觉换成"远程对话"主题。

## 已发布

- **v1.1.8**：MCP Server P0-P2（设置页、事件去重、协议协商、MCP 徽标、端口回退）、Windsurf hooks、TRAE IDE hooks 修复
- **v1.1.9**：MCP 全功能 + TRAE Work 自动注入（mcp.json + skill + user_rules）+ 45s idle 兜底 + 安装验证

## 进行中：v1.2.0 远程 AI 对话（核心功能，Pro 付费）—— P0

**需求（用户确认的核心）**：人在外面，手机远距离操控电脑上的 AI 对话——发消息、看回复、继续多轮。

**形态边界（已校准）**：NotchDeck 托管会话（手机 ↔ Mac 上的 headless agent 多轮对话），**不是**接管用户桌面上已开的 TUI 窗口（agent 无注入接口，不可行）。

**架构**（CloudKit 私有库，双端共享基建）：
- 容器：`iCloud.com.notchdeck`（双端 entitlement + 后台创建）
- 记录类型：`RemoteConversation`（sessionId / messages[] / status / updatedAt；iPhone 读写，Mac 订阅执行）
- Mac 端**会话管理器**：headless agent 多轮（`claude -p --resume` / `codex exec`，自维护 context），串行队列，消息回写
- 通道：CKSubscription + 远程通知 + 30s 轮询兜底
- 安全：Mac「允许远程对话」开关默认关（已实现，设置页）；私有数据库开发者不可见

**状态（2026-08-06）**：✅ 骨架完成（commit 2a8406d + 69cdf62：共享模型 + Mac Service/Manager + iOS View/ViewModel + 双端 entitlements + 设置开关 + i18n，双端编译通过）
**剩余**：①Apple 后台创建容器 iCloud.com.notchdeck（生产 schema 部署）②双端 iCloud 登录同一账号 ③Mac 打开开关 ④端到端联调（iPhone 发消息 → Mac 执行 claude → 回复回传）⑤UI 打磨 ⑥v1.2.0 发布（公证+appcast+Release+cask）

**定价**：Pro 功能（与"无限工具/历史统计"等打包）

**隐私表述调整**：README/PH 的"本地处理、无云" → "本地处理；可选 iCloud 同步（数据只进你的 iCloud，开发者不可见）"

## PH 首发（v1.2.0 完成后）

- 物料已备：docs/product-hunt-launch.md（tagline/描述/first comment/时间线）+ 演示 GIF（notchdeck-demo.gif + notchdeck-phone-demo.gif）
- 首发前更新：主视觉换"远程对话"主题 GIF（手机发消息 → Mac 执行 → 回复回传动画）
- 首发后：HN / Reddit / X 同步（文案在 launch doc 基础上生成）

## 远期

- **Windows 客户端**（hooks 层跨平台化 + Tauri/Electron + 任务栏形态）——市场最大（SO 2025：Windows 专业 49.5% vs macOS 32.9%），差异化弱于刘海，需产品重定位
- **局域网模式**（同一 Wi-Fi 手机看状态，零后端）——低成本补充
- **变现**：open-core（核心 MIT 开源 + Pro 闭源付费：远程对话 / 无限工具 / UsageCost 统计 / 云同步 / 主题）
