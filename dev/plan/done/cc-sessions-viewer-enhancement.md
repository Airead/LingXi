# cc_sessions viewer 增强计划

## 概述

分 4 个阶段逐步完善 cc_sessions viewer，每个阶段集中解决一类问题，降低上下文切换成本。

---

## Phase 1: Viewer 前端体验优化

**目标**：让 viewer 从"能看"变成"好用"。

### 1. Copy Buttons

**范围**：`viewer.js`, `viewer.html` (CSS)

**内容**：
- 代码块右上角添加复制按钮（hover 显示）
- 单条消息右上角添加复制按钮（hover 显示）
- 点击后通过 `lingxi` bridge 写入剪贴板
- 复制成功显示 checkmark，1.5s 后恢复

**依赖**：无
**影响面**：纯前端

### 2. Collapsible 长内容

**范围**：`viewer.js`, `viewer.html` (CSS)

**内容**：
- 用户消息和助手回复超过 8 行时自动折叠
- 底部显示渐变遮罩 + "Show more" 按钮
- 展开后显示 "Show less" 按钮
- CSS `max-height` + `overflow: hidden` + 伪元素渐变

**依赖**：无
**影响面**：纯前端

### 3. Tool Blocks 合并

**范围**：`viewer.js`

**内容**：
- 参考 WenZi 版 `buildBlocks()` 实现：相邻同类型 mergeable 工具（Read/Glob/Grep/Edit）自动合并
- 合并后 header 显示 `Read 3 files`，展开后列出每个工具的 input/output
- 非 mergeable 工具（Bash/Write/Agent）保持单独显示

**依赖**：无
**影响面**：纯前端，修改 `renderAssistantContent` 中的 block 构建逻辑

### 4. Stats Dashboard

**范围**：`viewer.js`, `viewer.html` (CSS)

**内容**：
- 在 info-bar 下方添加可折叠的统计面板
- 统计项：
  - 消息数、token 用量（in/out）
  - 工具调用次数排行（柱状图）
  - 模型使用统计（如果有）
  - 子 agent 列表（如果有）
- 点击标题栏展开/折叠

**依赖**：数据来自已有的 `messages` 数组，无需后端改动
**影响面**：纯前端

---

## Phase 2: Subagent 与导航

**目标**：支持复杂的 Agent 工作流会话。

### 5. Subagent 支持

**范围**：`viewer.js`, `init.lua`

**内容**：
- **前端**：检测 `tool_use` 中 `name === "Agent"` 的调用
- **后端**：Lua 提供 `list_subagents` 和 `check_subagent_exists` 接口（扫描 root session 目录下的子 session）
- **前端**：Subagent tool block 上显示 "View Session" 按钮（如果子 session 存在）
- 点击按钮通过 bridge 通知 Lua 打开子 session viewer
- 显示 subagent model tag

**依赖**：需要后端新增 Lua 接口
**影响面**：前后端联动

### 6. Parent Session Link

**范围**：`viewer.js`, `viewer.html` (CSS), `init.lua`

**内容**：
- 后端在发送 session info 时标记 `is_subagent: true` 并带上 `parent_file_path`
- 子 agent viewer 的 info-bar 显示 `← Parent Session` 链接
- 点击后通过 bridge 通知 Lua 打开父 session
- 子 agent viewer 隐藏 "Copy Resume Command" 按钮

**依赖**：Phase 5（Subagent 支持）
**影响面**：前后端联动

---

## Phase 3: 搜索与预览增强

**目标**：提升搜索结果的展示质量。

### 7. Preview Panel 升级

**范围**：`src/preview.lua`

**内容**：
- 从纯文本预览改为 HTML 预览（参考 WenZi 版 `preview.py`）
- 添加 metadata pills：project、branch、version、msg count、token count
- 时间信息：created、modified、duration
- 最近 10 轮对话（当前是 5 轮），带角色标签和颜色
- 使用 `lingxi` 的 HTML preview API

**依赖**：需要确认 LingXi 的 preview API 是否支持 HTML
**影响面**：后端（Lua）

### 8. Delete 操作

**范围**：`init.lua`

**内容**：
- 搜索结果中按 `Delete` 键将 session 文件移入 Trash
- 显示确认提示（`lingxi.alert.show` 或确认对话框）
- 删除后刷新搜索结果
- ⚠️ **危险操作**：不可逆，必须二次确认

**依赖**：无
**影响面**：后端（Lua），涉及文件系统操作

---

## Phase 4: 视觉优化

**目标**：美化搜索结果界面。

### 9. Project Identicon

**范围**：`src/identicon.lua`, `init.lua`

**内容**：
- 为每个 project 生成两字母 SVG 头像（参考 WenZi 版 `identicon.py`）
- 颜色根据 project 名哈希确定，保证同一项目颜色一致
- 在搜索结果中显示为 item icon

**依赖**：无
**影响面**：后端（Lua），生成 SVG 字符串

---

## 实施顺序图

```
Phase 1 ──────────────────────────────>
  ├─ 1. Copy Buttons
  ├─ 2. Collapsible 长内容
  ├─ 3. Tool Blocks 合并
  └─ 4. Stats Dashboard

Phase 2 ──────────────────────────────>
  ├─ 5. Subagent 支持
  └─ 6. Parent Session Link (依赖 5)

Phase 3 ──────────────────────────────>
  ├─ 7. Preview Panel 升级
  └─ 8. Delete 操作

Phase 4 ──────────────────────────────>
  └─ 9. Project Identicon
```

---

## 注意事项

1. **测试隔离**：所有测试使用临时目录和 mock 数据，不得触碰真实 `~/.claude/projects/`
2. **前端改动**：viewer.html 和 viewer.js 是核心，尽量保持与 WenZi 版的行为一致
3. **bridge 通信**：JS ↔ Lua 通信通过 `window.lingxi.postMessage` 和 `lingxi.webview.on_message`，每次新增 action 需要两端同步注册
4. **Delete 确认**：Phase 3 的 Delete 操作必须等待用户明确确认后才能执行
