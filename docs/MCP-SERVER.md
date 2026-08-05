# NotchDeck MCP Server — 设计方案

> 状态：草案 v0.1（2026-08-05）
> 目标：让**任何支持 MCP 的工具**（TRAE Work、Cursor、Windsurf、Claude Desktop、OpenHands、Copilot 等）都能向 NotchDeck 刘海面板推送实时事件，补上 hooks 路线覆盖不到的产品（典型：TRAE Work）。

## 1. 为什么需要 MCP Server

| 工具形态 | hooks 路线 | MCP 路线 |
|---|---|---|
| Claude Code / Codex / Gemini 等 CLI | ✅ 原生支持 | 可选 |
| Cursor / Trae IDE / Windsurf | ✅ 原生支持 | 可选 |
| Cline / Roo Code (VS Code) | ✅ 文件 hooks | 可选 |
| **TRAE Work（AI 办公平台）** | ❌ 官方不开放 hooks | ✅ MCP 是它的核心特性 |
| 其他支持 MCP 的工具 | ❌ 无 hooks 能力 | ✅ 通用 |

**核心洞察**：MCP（Model Context Protocol）是几乎所有新一代 AI 工具的事实标准。NotchDeck 做成一个 MCP server，一次接入 = 覆盖所有支持 MCP 的工具。TRAE Work 是决定性用例——它是 NotchDeck 当前唯一无法通过 hooks 接入的主流工具。

## 2. 原理与局限（先说清楚）

MCP 本质是**工具调用协议**（client 调 server 的 tool），不是事件订阅协议。让 agent 自动上报事件的机制：

- NotchDeck 暴露 MCP server，提供 `notchdeck_report` 类工具
- **依赖 agent 的规则/提示词引导**：在工具的自定义规则（rules）里写"每次会话开始、工具调用前后，调用 notchdeck_report 上报"——这是**软约束**（agent 一般会遵守，但不保证 100%）
- 比 hooks（硬性触发）弱一档，但胜在覆盖全

**可观测性分级**：
- 有 hooks 的工具：保真事件流（pre/post 精确语义）→ hooks 优先
- 只有 MCP 的工具：agent 引导上报（事件粒度取决于规则写得多细）

## 3. 架构

```
┌─────────────────────────────────────────────┐
│  工具（client）                              │
│  TRAE Work / Cursor / Windsurf / OpenHands  │
│        │  MCP (HTTP + SSE, localhost)       │
│        ▼                                    │
│  ┌──────────────────────────────┐           │
│  │  NotchDeck MCP Server        │           │
│  │  (app 内置 HTTP server)      │           │
│  │  · /mcp  JSON-RPC 2.0        │           │
│  │  · tools: notchdeck_report   │           │
│  │  · 复用 EventNormalizer      │           │
│  └──────────────┬───────────────┘           │
│                 │ 标准化 HookEvent          │
│                 ▼                           │
│  appState.recordHookEvent / handleEvent     │
│                 │                           │
│                 ▼                           │
│            刘海面板 UI（复用现有管线）        │
└─────────────────────────────────────────────┘
```

## 4. 协议设计

### 4.1 传输

- **HTTP + SSE**（MCP "Streamable HTTP" 传输，2025-03-26 起标准）：
  - 端点 `http://127.0.0.1:8765/mcp`
  - 仅监听回环地址，无外部暴露
- 不做 stdio 版（本地 CLI 有 hooks 已覆盖，桌面 app 需要 HTTP）

### 4.2 Tools

| Tool | 参数 | 说明 |
|---|---|---|
| `notchdeck_report` | `event`（必填）：`SessionStart`/`UserPromptSubmit`/`PreToolUse`/`PostToolUse`/`Stop`/`Notification`/`SessionEnd`<br>`session_id`（必填）<br>`cwd`（可选）<br>`tool_name`（可选，PreToolUse/PostToolUse 用）<br>`tool_input`（可选）<br>`detail`（可选，自由文本） | 通用事件上报入口 |
| `notchdeck_status` | — | 健康检查 + 返回 NotchDeck 版本（辅助 agent 确认联通） |

事件名直接复用现有 `EventNormalizer` 内部命名空间，无需新归一化。

### 4.3 JSON-RPC 形状（示例）

```json
// client -> server
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
  "name":"notchdeck_report",
  "arguments":{
    "event":"PreToolUse",
    "session_id":"sess-abc123",
    "cwd":"/Users/me/proj",
    "tool_name":"RunCommand",
    "detail":"npm run build"
  }
}}
```

server 内部：构造 `HookEvent` → `appState.recordHookEvent(...)` → `appState.handleEvent(event)`，与 socket 事件完全同管线。

### 4.4 Source 标记

- 事件注入 `_source` 字段：工具名小写（如 `trae-work`、`cursor`、`windsurf`），需加入 `SessionSnapshot.supportedSources` 白名单（否则会被 processRequest 的 source 校验丢弃）
- `_via_plugin: true` 语义：MCP 上报 = 插件代理来源（面板可显示来源徽标）

## 5. 接入指引（各工具）

### TRAE Work（决定性用例）

1. 打开 TRAE Work → 智能体设置 → MCP Server → 添加：
   - 类型：HTTP/SSE（或 Remote）
   - URL：`http://127.0.0.1:8765/mcp`
2. 在自定义规则（Rules / 技能）中写入引导：

```markdown
每次会话开始时、每次工具调用前后、每次输出完成时，
调用 MCP server "notchdeck" 的 notchdeck_report 工具上报事件：
- 会话开始: notchdeck_report(event="SessionStart", session_id=当前会话ID)
- 工具调用前: notchdeck_report(event="PreToolUse", ..., tool_name=工具名)
- 工具调用后: notchdeck_report(event="PostToolUse", ...)
- 输出完成: notchdeck_report(event="Stop", ...)
```

### Cursor / Windsurf / Claude Desktop / OpenHands 等

- 设置 → MCP 配置加 `http://127.0.0.1:8765/mcp` + 同样的规则引导
- 有 hooks 的工具：hooks 优先（保真），MCP 作为兜底/可选

## 6. 安全

- 仅绑定 `127.0.0.1`，不监听外部接口
- 只接收本地事件，无网络外发（与 NotchDeck 隐私承诺一致：本地处理、无遥测）
- 事件内容不落盘（与 socket 事件同处理）
- 可加鉴权 token（可选，默认关闭——回环地址风险可控）

## 7. 实现计划

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | HTTP server（Swift 原生，复用 CodeIslandCore）+ JSON-RPC 2.0 + tools/list + tools/call → HookEvent → handleEvent | ✅ 1.1.8 |
| P0 | supportedSources 加 `trae-work`/`windsurf`/`zoo-code`/`openhands` 等 + 面板来源徽标 | ✅ 1.1.8 |
| P1 | 面板设置页加「MCP Server」开关 + 显示状态（监听中/事件数） | ✅ 1.1.8 |
| P1 | 事件去重（同 source/session_id/时间窗 5s） | ✅ 1.1.8 |
| P1 | 各工具接入指引文档（README + docs/） | ✅ 1.1.8 |
| P2 | 设置页 Start/Stop/Restart 按钮 + 事件计数流式刷新 | ✅ 1.1.8 |
| P2 | MCP 专属通知样式（会话卡片 MCP 徽标）+ protocolVersion 协商回显 | ✅ 1.1.8 |
| P2 | MCP 端口冲突自动换端口（8765 被占 → 8766+，设置页显示实际端口+警告） | ✅ dev |
| P2 | 可选：stdio 传输（给终端 CLI）、SSE 流式 notifications | ❌ 评估后不做：MCP server 是"被调用"角色，SSE 推送对 AI agent 客户端无消费方；stdio 传输同理（terminal CLI 直接走 hooks）；协议 v2025-06-18 兼容已足够 |

依赖：无（Swift 标准库 + Network/Foundation 即可；MCP SDK 有 Swift 版但可手写 JSON-RPC，协议简单）

## 8. 与 hooks 的关系

- **双轨策略**：hooks 提供硬性、精确的事件；MCP 提供全覆盖兜底
- 同一工具两条都配时：事件可能重复 → 服务端按 (source, session_id, event_name) 5s 窗口去重（✅ P1，MCPServer.handleReport）
- 面板「连接方式」列显示每条会话来自 hooks / MCP / 两者（MCP-only source 会话卡片带「MCP」徽标）

## 9. 开放问题

1. TRAE Work 的 agent 能否稳定调用 notchdeck_report？→ **v1.1.9 已实现自动注入**（ConfigInstaller 写 TRAE User/mcp.json + 最近 workspace 的 AGENTS.md/CLAUDE.md，TRAE 默认导入 CLAUDE.md）。剩余不确定项：规则在会话启动快照 → 用户需新开会话（平台限制）；已实测自动注入文件写入成功，agent 调用稳定性待用户最终验证（docs/TRAE-WORK-MCP-TEST.md 第 0 节）
2. MCP server 端口冲突处理（8765 被占则自动换端口 8766-8775，设置页显示实际端口 + 警告）✅ dev（commit e02679b）
3. 是否需要 `notchdeck_session_start` 专用工具（强约束 agent 在会话开始必须调用）？
4. ZooCode（Roo Code 社区 fork）确认走 MCP 路线（`.roo/mcp.json`），无专门 hooks 适配（✅ 调研结论）
5. **开箱即用扩展**：MCP 自动注入模式（TRAE Work 已实现）可推广到其它无 hooks 工具（Zoo Code 的 .roo/mcp.json 类似）——按需评估

---

*附：实测验证步骤（远程 Mac / 本机）*
1. 起 app，面板设置开 MCP
2. `curl -X POST http://127.0.0.1:8765/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'`
3. `curl ... tools/call notchdeck_report ...` → 面板应出现反馈
4. TRAE Work 加 MCP server + 规则 → 发消息 → 观察面板
