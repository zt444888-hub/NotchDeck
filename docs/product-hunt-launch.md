# NotchDeck Product Hunt 首发作战手册

> 目标窗口：**周四 PST 早 7:00（= 北京时间周四 23:00）** —— PH 算法黄金时间
> 建议：周三晚备料 → 周四白天预热 → 周四 23:00 发布 → 头 2 小时在线互动

---

## 一、为什么是 Product Hunt

- 全球最大新产品社区，AI/开发者工具的**首发主阵地**（Cursor、Raycast 等都在 PH 首发过）
- 单次成功首发可带来 5k-50k 访客，且**长尾持续**（Google 搜索 "notch ai" 类词会带流量）
- NotchDeck 是视觉产品——PH 的图片/视频优先展示机制正好放大优势

---

## 二、发布前准备（提前 1-2 天，即明天白天）

### 1. 账号
- 用 X / Google 账号登录 [producthunt.com](https://www.producthunt.com)
- 完善个人 profile（头像、bio 写"iOS/macOS indie dev"）

### 2. 必备物料清单（对照打勾）
- [ ] **主视觉图（最关键）**：1 张演示动图（GIF）——Claude Code 干活 → 刘海面板实时跳动 → 完成。1440x810 或 16:9。PH 首页展示位
- [ ] 5-8 张截图：面板展开、会话列表、批准/问题弹窗、设置页（Hooks 列表）、MCP 设置页、手机 companion（iPhone 镜像）
- [ ] **YouTube 演示视频**（1-2 分钟，可选项但推荐）：录屏 + 简单字幕
- [ ] 官网/GitHub 链接：`https://github.com/zt444888-hub/NotchDeck`（放 release 下载）

### 3. 预约 upvote（发布前 12-24h 做）
- PH 支持建好页面后生成 **secret sneak-peek 链接**
- 把链接发给：朋友、开发者群（Discord/微信）、X 关注者——让他们预约（发布当天自动投票）
- **早期 upvote 速度和数量决定排名**，预约是拿到早期票的关键

### 4. 预热（发布当天上午）
- X 上发："Tomorrow on Product Hunt — NotchDeck, live AI agent status in your MacBook notch" + 演示视频
- 提前告诉 3-5 个技术朋友发布时来评论（评论质量影响算法）

---

## 三、发布当天（周四 23:00 北京时间）

1. **准点点击 Publish**
2. **立即在 first comment 区发技术评论**（见下方物料）
3. **头 2 小时在线**：逐条回复所有评论（一条好回复 = 一条广告）
4. 发布 1 小时后（PST 8am）在 X/社群发第二次："Live now on Product Hunt" + 链接
5. 第二天早上（欧洲时段）再补一轮回复

---

## 四、PH 物料（可直接复制）

### Name
```
NotchDeck
```

### Tagline（≤60 字符）
```
Live AI agent status in your MacBook notch
```
> 备选：`See what your AI coding agent is doing, right in the notch`

### Description（Markdown 正文）

```
Your AI coding agent works invisibly. When it gets stuck, burns tokens, or
needs approval — you find out after the damage is done.

**NotchDeck puts a live status panel in your MacBook notch**, showing exactly
what your agent is doing in real time: thinking, running tools, waiting for
approval, or finished.

**Works with 30+ AI tools — zero config:**
- Native hooks for Claude Code, Codex, Gemini CLI, Cursor, Trae, Windsurf,
  Qoder, and 25+ more (auto-installed on first launch)
- Built-in MCP server for anything else — TRAE Work, Zoo Code, OpenHands…
  (config auto-injected, just start a new conversation)
- iPhone & Apple Watch companion mirrors the island via Bluetooth

**Every event is local.** Hooks and MCP reports stay on your machine —
no cloud, no telemetry, no account. MIT-licensed open source.

Watch your agent work, catch failures early, and never lose track of what
your AI is doing again.
```

### Topics / Tags
```
Mac, Artificial Intelligence, Developer Tools, Open Source, Developer Experience
```

### First Comment（发布后立刻贴，置顶展示位）

```
Hi PH! I built NotchDeck because my AI agents were working invisibly —
I'd only notice when something broke.

Two integration paths, because the AI tool landscape is fragmented:

1. **Native hooks** for Claude Code, Codex, Cursor, Trae, Windsurf and
   25+ CLIs — auto-installed, no config, event-perfect (PreToolUse,
   PostToolUse, Stop...).

2. **A built-in MCP server** (localhost:8765) for tools with no hooks —
   TRAE Work, Zoo Code, OpenHands. For TRAE Work I reverse-engineered
   its config storage and now auto-inject the MCP entry + rules, so it's
   close to zero-config too (one nudge message per new conversation).

Everything runs locally — the notch panel, the socket bridge, the MCP
server. No cloud, no account, no telemetry. MIT-licensed.

iPhone/Apple Watch companion mirrors the island over Bluetooth.

Would love your feedback — especially on the MCP side, since that's the
fastest-growing part of the AI tool ecosystem right now.
```

### Maker(s)
```
zt444888-hub（你）
```

---

## 五、发布后 24-72h

1. 持续回复评论（算法看互动持续性）
2. 把 PH 流量导向 GitHub（README 顶部放 star 按钮 + 演示 GIF）
3. 收集 feedback → 记入 v1.2.0 计划
4. 发布第二天在 X 发"Thank you"帖 + 数据截图（如有排名）

---

## 六、关键提醒

- **主视觉必须是动态演示**（GIF/视频）——静态截图浪费 NotchDeck 的视觉优势
- **tagline 超 60 字符会被截断**
- **发布前别让 PH 页面"半成品"曝光**（secret 链接只给预约的人）
- 首发当天不要同时发 HN（会分流）——HN 建议隔 2-3 天再发
