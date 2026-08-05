# NotchDeck Roadmap

> 维护：2026-08-05 更新。优先级按产品价值 × 成本排序。

## 已发布

- **v1.1.8**：MCP Server P0-P2（设置页、事件去重、协议协商、MCP 徽标、端口回退）、Windsurf hooks、TRAE IDE hooks 修复
- **v1.1.9**：MCP 全功能 + TRAE Work 自动注入（mcp.json + skill + user_rules）+ 45s idle 兜底 + 安装验证

## 近期收尾（本周）

1. **手机端 BLE 链路收尾**：真机连接已通（扫描 → 连接 → 状态同步验证中）；Live Activity/StandBy/Watch 真机验证
2. **Product Hunt 首发**（周四 23:00 窗口）：物料已备（docs/product-hunt-launch.md + 演示 GIF）
3. 补推 GitHub 网络阻塞的提交（已恢复）

## v1.2.0：CloudKit 云同步 + 远程任务（Pro 付费功能）

**需求**：人在外面远程指挥 Mac 上的 AI（手机发指令 → Mac headless agent 执行 → 结果回传）。

**架构**（同一套 CloudKit 基建，两个功能一起做）：
- 容器：`iCloud.com.notchdeck`（双端 entitlement + 后台创建）
- 记录类型：
  - `CompanionState`（状态快照，Mac 写 / iPhone 订阅推送）
  - `RemoteCommand`（远程命令：id / text / status[pending→running→done] / result / createdAt；iPhone 写 / Mac 订阅执行）
- 通道：CKSubscription + 远程通知 + 30s 轮询兜底（推送不可靠时的保底）
- 执行：Mac 端 spawn headless agent（`claude -p` / `codex exec`），串行队列，状态机 pending→running→done
- 安全：Mac 端「允许远程执行」开关默认关（用户手动开）；私有数据库 = 数据仅用户设备可见，开发者不可见

**工程量**：4-5 个工作日
| 项 | 估时 |
|----|------|
| 双端 iCloud capability + 容器/schema | 0.5 天 |
| Mac：CloudKit 订阅/拉取 + 命令执行器 + 回写 | 1.5-2 天 |
| iPhone：命令输入 UI + 列表 + 结果订阅 | 1-1.5 天 |
| 联调（弱网/推送延迟/队列） | 1 天 |

**定价**：Pro 功能（与"无限工具/历史统计"等打包）

**隐私表述调整**：README/PH 的"本地处理、无云" → "本地处理；可选 iCloud 同步（数据只进你的 iCloud，开发者不可见）"

## 远期

- **Windows 客户端**（hooks 层跨平台化 + Tauri/Electron + 任务栏形态）——市场最大（SO 2025：Windows 专业 49.5% vs macOS 32.9%），差异化弱于刘海，需产品重定位
- **局域网模式**（同一 Wi-Fi 手机看状态，零后端）——低成本补充
- **变现**：open-core（核心 MIT 开源 + Pro 闭源付费：无限工具 / UsageCost 统计 / 云同步 / 远程任务 / 主题）
