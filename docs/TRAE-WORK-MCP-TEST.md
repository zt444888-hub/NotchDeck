# TRAE Work × NotchDeck 实测指引

> 目标：验证 TRAE Work 的 agent 能稳定调用 `notchdeck_report`，让刘海面板实时显示
> TRAE Work 会话状态。这是 MCP Server（P0/P1）的最终验收。
>
> **v1.1.9 起：TRAE Work 已开箱即用（zero-config）**——NotchDeck 启动时自动
> 注入 MCP server 条目到 TRAE 的 `User/mcp.json`，并自动写入 AGENTS.md +
> CLAUDE.md 规则到最近使用的 workspace（TRAE 默认导入 CLAUDE.md）。用户
> **无需任何手动配置**，只需在 TRAE 新开会话。
>
> 前置条件：NotchDeck 已启动且 MCP Server 监听中
> （Settings → MCP 显示 Listening，或 `nc -z 127.0.0.1 8765` 返回 PORT OPEN）。

## 0. 快速验证（v1.1.9 开箱即用路径）

1. 确认 NotchDeck 已启动（设置 → Hooks 里 TRAE Work 状态为「已激活」）
2. 打开 TRAE Work 桌面版，**新开一个会话**（规则在会话启动时快照，旧会话无效）
3. 正常聊天发任务即可——agent 按注入的规则自动调用 `notchdeck_report`
4. 刘海面板出现 trae-work 会话并实时更新

> 注意：TRAE 的 MCP 面板里 notchdeck 若未显示「已就绪」，重启 TRAE 一次
> （让它重新读取 mcp.json）。首次使用请确认运行环境为「本地」。

## 1. 手动添加 MCP Server（fallback，v1.1.9 前或自动注入失效时）

1. 打开 **TRAE Work 桌面版**（网页版无法访问本机 127.0.0.1，必须桌面版）
2. 左下角点击 **头像** → **设置**
3. 左侧导航栏选择 **MCP**，进入 MCP Server 管理面板
4. **运行环境选择「本地」**（关键：云端环境无法访问你 Mac 上的 localhost）
5. 在 MCP Servers 管理部分，右上角 **创建** → **手动配置**
6. 填入以下配置：

```json
{
  "mcpServers": {
    "notchdeck": {
      "url": "http://127.0.0.1:8765/mcp"
    }
  }
}
```

7. 点击 **确认**。面板应从「准备中」变为「已就绪」（绿色对勾）

> 若使用 TRAE IDE 模式：右上角 设置 → MCP → 添加 > 手动添加，同一段 JSON 即可。

## 2. 给智能体绑定 MCP Server

- 内置智能体 **Builder with MCP** 会自动加载所有已配置的 MCP Server，无需手动绑定。
- 若使用自定义智能体：在 MCP Server 列表点击 notchdeck 右侧 **+**，勾选要绑定的智能体 → 确认。

## 3. 规则引导（让 agent 主动调用）

新建/编辑一条 TRAE Rules（或直接在对话里粘贴），内容：

```
开始每轮对话时，调用 MCP 工具 notchdeck_report 汇报状态：
1. 会话开始时：event=SessionStart，session_id 用稳定会话标识
2. 收到用户消息时：event=UserPromptSubmit，detail 带上消息摘要
3. 每次使用工具前：event=PreToolUse，tool_name 写工具名
4. 每个工具完成后：event=PostToolUse，tool_name 写工具名
5. 一轮回答结束时：event=Stop
source 固定为 trae-work。
```

## 4. 验证清单

| # | 操作 | 预期 |
|---|------|------|
| 1 | 设置里 MCP 面板显示已就绪 | 绿色对勾，无报错 |
| 2 | 对话窗口输入「调用 notchdeck_status 确认连接」 | agent 返回 NotchDeck 版本号 |
| 3 | 开始一次新对话 | 刘海面板出现 trae-work 会话，SessionStart 生效 |
| 4 | 发一条消息让 agent 干活 | 面板显示 UserPromptSubmit / PreToolUse 活动 |
| 5 | 等 agent 完成回答 | 面板显示 Stop，会话转入 idle |

## 5. 故障排查

| 症状 | 原因 | 处理 |
|------|------|------|
| MCP 面板一直「准备中」 | 运行环境选了「云端」 | 切到「本地」 |
| 调用报连接失败 | NotchDeck 未运行 / MCP 未开启 | Settings → MCP 确认 Listening；`nc -z 127.0.0.1 8765` |
| agent 不主动调用工具 | 规则未生效 | 用内置 Builder with MCP 智能体重试；确认规则内容粘贴 |
| 事件进了但没显示 | source 不在白名单 | 确认 source=trae-work（已在 v1.1.7 白名单） |

## 6. 补充：手动冒烟测试（不依赖 TRAE）

```bash
# 健康检查
curl -s -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"notchdeck_status","arguments":{}}}'

# 模拟一次完整会话
curl -s -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notchdeck_report","arguments":{"event":"SessionStart","session_id":"trae-work-manual-001","source":"trae-work"}}}'
curl -s -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"notchdeck_report","arguments":{"event":"PreToolUse","session_id":"trae-work-manual-001","source":"trae-work","tool_name":"bash"}}}'
curl -s -X POST http://127.0.0.1:8765/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"notchdeck_report","arguments":{"event":"Stop","session_id":"trae-work-manual-001","source":"trae-work"}}}'
```

每步返回 `{"result":{"content":[{"type":"text","text":"ok"}]}}` 即通路正常；刘海面板应出现
`trae-work-manual-001` 会话。
