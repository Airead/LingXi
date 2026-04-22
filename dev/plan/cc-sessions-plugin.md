# LingXi Claude Code Sessions 插件实现计划

## 背景

为 LingXi 开发一个对标 WenZi `cc_sessions` 插件的 Claude Code 会话浏览功能。用户输入前缀 `cc ` 后，可搜索、浏览和查看 Claude Code 会话历史，支持项目过滤、模糊匹配、文本预览和 WebView 查看器。

## 目标

1. **复刻 WenZi 核心体验**：前缀搜索、项目过滤（`@` 语法）、模糊匹配、会话查看
2. **新增宿主 WebView 能力**：为 Lua 插件系统增加 WebView 窗口支持，实现双向消息通信
3. **精简查看器**：从 WenZi 的 1978 行单文件 viewer.html 精简到约 800 行核心渲染逻辑
4. **暂不支持**：实时刷新、OpenCode 兼容、子代理跳转

## WenZi 参考

| 文件 | 说明 |
|------|------|
| `/Users/fanrenhao/work/WenZi/plugins/cc_sessions/init_plugin.py` | 核心实现（注册 Chooser Source、命令、查看器逻辑） |
| `/Users/fanrenhao/work/WenZi/plugins/cc_sessions/scanner.py` | 会话扫描器（发现 `~/.claude/projects/` 下的 JSONL 文件） |
| `/Users/fanrenhao/work/WenZi/plugins/cc_sessions/reader.py` | JSONL 读取器（提取对话轮次和 Token 用量） |
| `/Users/fanrenhao/work/WenZi/plugins/cc_sessions/preview.py` | 预览面板 HTML 生成器 |
| `/Users/fanrenhao/work/WenZi/plugins/cc_sessions/cache.py` | 持久化磁盘缓存 |
| `/Users/fanrenhao/work/WenZi/plugins/cc_sessions/identicon.py` | 项目头像生成器（SVG 两字母头像） |
| `/Users/fanrenhao/work/WenZi/plugins/cc_sessions/viewer.html` | 会话查看器前端（单文件 HTML+CSS+JS，1978 行） |
| `/Users/fanrenhao/work/WenZi/plugins/cc_sessions/plugin.toml` | 插件元数据配置 |

## LingXi 现有代码

| 文件 | 说明 |
|------|------|
| `/Users/fanrenhao/work/LingXi/LingXi/Plugin/LuaSearchProvider.swift` | Lua 插件搜索提供者 |
| `/Users/fanrenhao/work/LingXi/LingXi/Plugin/LuaAPI.swift` | Lua API 注册中心（`lingxi.*` 模块注册） |
| `/Users/fanrenhao/work/LingXi/LingXi/Plugin/PluginManager.swift` | 插件加载、注册到 SearchRouter |
| `/Users/fanrenhao/work/LingXi/LingXi/Plugin/PluginManifest.swift` | 插件权限和数据结构定义 |
| `/Users/fanrenhao/work/LingXi/LingXi/Plugin/ManifestParser.swift` | TOML 清单解析器 |
| `/Users/fanrenhao/work/LingXi/plugins/api-showcase/init.lua` | 现有 Lua API 示例参考 |
| `/Users/fanrenhao/work/LingXi/plugins/emoji-search/init.lua` | 复杂搜索逻辑参考（模糊匹配、预览） |

---

## 设计决策

### D1: WebView API 设计

WenZi 通过 `wz.ui.webview_panel()` 打开 WebView 面板，支持双向消息。LingXi 需要新增 `lingxi.webview.*` API。

**方案**：

```lua
-- 打开 WebView 窗口
lingxi.webview.open("viewer.html", {
    title = "Session Title",
    width = 900,
    height = 700
})

-- 发送消息到 JS
lingxi.webview.send('{"action":"session_data","messages":[...]}')

-- 注册消息回调
lingxi.webview.on_message(function(data)
    if data.action == "copy" then
        lingxi.clipboard.write(data.text)
    elseif data.action == "close" then
        lingxi.webview.close()
    end
end)
```

**JS 侧全局对象**：

```javascript
// 发消息到 Lua
window.lingxi.postMessage({action: "init", filePath: "..."});

// 收消息来自 Lua
window.onLingXiMessage = function(data) {
    if (data.action === "session_data") render(data);
};
```

**Swift 实现**：
- `PluginWebViewManager`：单例，限制同时只有一个插件 WebView
- `PluginWebViewWindow`：单个 WKWebView 窗口，注入 `window.lingxi` JS 对象
- `WKScriptMessageHandler`：接收 JS → Swift 消息，转发到 Lua 回调
- `PermissionConfig` 新增 `webview: Bool` 字段

### D2: 通信协议

**JS → Lua 消息类型**：

| action | 数据 | 说明 |
|--------|------|------|
| `init` | `{filePath}` | 查看器加载完成，请求会话数据 |
| `copy` | `{text}` | 复制文本到剪贴板 |
| `close` | `{}` | 关闭窗口 |

**Lua → JS 消息类型**：

| action | 数据 | 说明 |
|--------|------|------|
| `session_data` | `{info, messages}` | 发送解析后的会话数据 |

**数据传输格式**：
- Lua 侧一次性读取 JSONL，解析后发送结构化数据（而非原始 JSONL 文本）
- 避免 JS 端重复解析，减少传输体积
- 消息过大时分批发送（后续优化）

### D3: viewer.html 精简策略

WenZi 的 viewer.html 为 1978 行单文件内联，包含完整功能。

**保留（核心渲染，约 800 行）**：
- Markdown 渲染 + 代码高亮（marked.js + highlight.js）
- 消息布局（user/assistant 区分）
- 工具调用块（简化版，不合并、无子代理）
- 大纲导航
- 自动滚动底部

**移除**：
- 统计面板（-250 行 JS + CSS）
- 子代理解析与跳转（-120 行）
- 彩虹边框动画、Live Glow（-40 行 CSS）
- 复制按钮、内容折叠（-60 行）
- 主题切换（固定暗色主题）
- `wz-file://` 协议读取，改为接收 Lua 发送的数据

**文件拆分**：
- `viewer.html`：HTML 骨架 + CSS
- `viewer.js`：核心渲染逻辑
- `vendor/`：marked.min.js, highlight.min.js, github-dark.min.css

### D4: 文件系统权限

扫描路径：`~/.claude/projects/` 下的 `*.jsonl` 文件。

**方案**：
- `plugin.toml` 声明 `filesystem = ["~/.claude", "~/.claude/projects"]`
- Lua 侧使用 `lingxi.file.list()` 和 `lingxi.file.read()` 读取
- 注意 `PathValidator` 是否支持 `~` 展开，如不支持则通过 `lingxi.shell.exec("echo $HOME")` 获取真实路径

### D5: 缓存策略

WenZi 使用磁盘 JSON 缓存 + 内存 TTL。LingXi 使用 `lingxi.store`（key-value）。

**方案**：
- 缓存键：`cc_sessions:scan_result` + `cc_sessions:scan_timestamp`
- TTL：30 秒
- 缓存内容：会话元数据摘要（非完整消息），避免存储过大

```lua
local cache = {
    key = "cc_sessions:scan_result",
    ttl = 30,
}

function cache.get()
    local data = lingxi.store.get(cache.key)
    local timestamp = lingxi.store.get(cache.key .. ":timestamp")
    if data and timestamp then
        if (os.time() - tonumber(timestamp)) < cache.ttl then
            return lingxi.json.parse(data)
        end
    end
    return nil
end
```

### D6: 搜索结果预览

WenZi 使用 HTML 预览面板。LingXi 当前仅支持 `preview_type = "text"`。

**方案**：
- 阶段 1 使用 `.text` 预览，显示最近 5 轮对话摘要 + 元数据
- 阶段 2 评估是否需要扩展 `PreviewData.html`，或保持文本预览

### D7: 插件文件结构

```
cc-sessions/
├── plugin.toml              # 插件配置
├── init.lua                 # 入口：search(), 命令, 事件处理
├── scanner.lua              # 会话扫描器
├── reader.lua               # JSONL 读取与解析
├── preview.lua              # 文本预览生成
├── cache.lua                # 基于 lingxi.store 的缓存
├── identicon.lua            # SVG 项目头像
├── git_utils.lua            # Git 工具
├── viewer.html              # WebView 查看器（精简版）
├── viewer.js                # 查看器核心渲染逻辑
└── vendor/                  # 前端依赖
    ├── marked.min.js
    ├── highlight.min.js
    └── github-dark.min.css
```

---

## 实现阶段

### 阶段 1：宿主端 WebView API

**目标**：实现 `lingxi.webview.*` API，支持插件打开 WebView 窗口并进行双向通信。

#### 1.1 新增权限类型

**修改文件**: `LingXi/Plugin/PluginManifest.swift`

```swift
struct PermissionConfig: Sendable, Equatable {
    let network: Bool
    let clipboard: Bool
    let filesystem: [String]
    let shell: [String]
    let notify: Bool
    let store: Bool
    let webview: Bool  // 新增
}
```

#### 1.2 新增 WebView 管理器

**新建文件**: `LingXi/Plugin/PluginWebViewManager.swift`

```swift
@MainActor
final class PluginWebViewManager {
    static let shared = PluginWebViewManager()
    
    func open(pluginId: String, htmlPath: String, title: String?, width: CGFloat, height: CGFloat)
    func close()
    func sendMessage(_ data: [String: Any])
}
```

**新建文件**: `LingXi/Plugin/PluginWebViewWindow.swift`

- 创建 `WKWebView` 窗口
- 加载插件目录下的 HTML 文件（支持 `plugin://` URL scheme）
- 注入 `window.lingxi` JS 对象（`postMessage` 方法）
- 通过 `WKScriptMessageHandler` 接收 JS 消息
- 转发到对应插件的 Lua `on_message` 回调

#### 1.3 新增 Lua WebView API

**修改文件**: `LingXi/Plugin/LuaAPI.swift`

注册 `lingxi.webview` 模块：

```lua
lingxi.webview.open(htmlPath, opts)     -- 打开窗口
lingxi.webview.close()                   -- 关闭窗口
lingxi.webview.send(jsonString)          -- 发送 JSON 到 JS
lingxi.webview.on_message(callback)      -- 注册消息回调
```

#### 1.4 解析 webview 权限

**修改文件**: `LingXi/Plugin/ManifestParser.swift`

解析 `plugin.toml` 中的 `permissions.webview` 字段。

**修改文件**: `LingXi/Plugin/PluginManager.swift`

加载插件时，若 `webview = true`，注册 WebView 权限。

#### 1.5 验证

- 新建测试插件，调用 `lingxi.webview.open("test.html")`
- 确认 WebView 窗口正确打开，加载插件目录下的 HTML
- JS 调用 `window.lingxi.postMessage()`，Lua 回调正确接收
- Lua 调用 `lingxi.webview.send()`，JS 的 `onLingXiMessage` 正确接收

---

### 阶段 2：插件骨架 + 扫描器

**目标**：实现插件基础结构和会话扫描功能。

#### 2.1 新建插件文件

**新建文件**: `plugins/cc-sessions/plugin.toml`

```toml
[plugin]
id = "io.github.airead.lingxi.cc-sessions"
name = "Claude Code Sessions"
version = "1.0.0"
author = "LingXi Team"
description = "Browse and view Claude Code session history"
min_lingxi_version = "1.1.0"

files = [
    "init.lua",
    "scanner.lua",
    "reader.lua",
    "preview.lua",
    "cache.lua",
    "identicon.lua",
    "git_utils.lua",
    "viewer.html",
    "viewer.js",
    "vendor/marked.min.js",
    "vendor/highlight.min.js",
    "vendor/github-dark.min.css",
]

[search]
prefix = "cc"
debounce = 100
timeout = 10000

[permissions]
clipboard = true
filesystem = ["~/.claude", "~/.claude/projects"]
shell = ["git"]
store = true
webview = true

[[commands]]
name = "cc-sessions:clear-cache"
title = "Clear CC Sessions Cache"
subtitle = "Clear the session scan cache"
action = "cmd_clear_cache"
```

**新建文件**: `plugins/cc-sessions/init.lua`

实现 `search(query)` 函数：
- 解析查询（项目过滤 `@项目名`、关键词）
- 调用 `scanner.lua:scan_all()` 获取会话列表
- 模糊匹配过滤
- 生成 `SearchResult` 列表

**新建文件**: `plugins/cc-sessions/scanner.lua`

- 遍历 `~/.claude/projects/*/` 目录
- 读取 `*.jsonl` 文件（通过 `reader.lua`）
- 提取：标题、项目名、分支、消息数、时间戳
- 应用缓存（`cache.lua`）

**新建文件**: `plugins/cc-sessions/reader.lua`

- 读取 JSONL 文件
- 逐行解析 JSON
- 提取：元数据、用户消息、助手消息、Token 用量
- 返回结构化数据

#### 2.2 验证

- 输入 `cc` → 显示最近会话列表
- 输入 `cc 关键词` → 模糊匹配过滤
- 输入 `cc @项目名` → 按项目过滤

---

### 阶段 3：预览 + 查看器

**目标**：实现搜索结果预览和 WebView 查看器。

#### 3.1 文本预览生成

**新建文件**: `plugins/cc-sessions/preview.lua`

生成搜索结果预览文本：
- 会话元数据（项目、分支、时间）
- 最近 5 轮对话摘要
- Token 用量概览

#### 3.2 项目头像生成

**新建文件**: `plugins/cc-sessions/identicon.lua`

- 基于项目名生成 SVG 两字母头像
- base64 data URI 格式

#### 3.3 查看器前端

**新建文件**: `plugins/cc-sessions/viewer.html`

HTML 骨架 + CSS 样式（暗色主题）。

**新建文件**: `plugins/cc-sessions/viewer.js`

核心渲染逻辑（从 WenZi 移植并精简）：
- `window.lingxi.postMessage({action: "init", filePath: ...})`
- `window.onLingXiMessage = function(data) { ... }`
- Markdown 渲染（marked.js）
- 代码高亮（highlight.js）
- 消息布局（user/assistant）
- 工具调用块（简化版）
- 大纲导航

**复制 vendor 文件**：
- 从 WenZi `cc_sessions/vendor/` 复制到 `plugins/cc-sessions/vendor/`

#### 3.4 打开查看器

**修改文件**: `plugins/cc-sessions/init.lua`

为每个搜索结果添加 action：

```lua
action = function()
    lingxi.webview.open("viewer.html", {
        title = session.title,
        width = 900,
        height = 700
    })
    -- 存储当前会话路径，供 on_message 使用
    _current_session_path = session.file_path
end
```

注册 `on_message` 回调：

```lua
lingxi.webview.on_message(function(data)
    if data.action == "init" then
        local content = lingxi.file.read(_current_session_path)
        local messages = reader.parse(content)
        lingxi.webview.send(lingxi.json.encode({
            action = "session_data",
            info = { ... },
            messages = messages
        }))
    elseif data.action == "copy" then
        lingxi.clipboard.write(data.text)
    end
end)
```

#### 3.5 验证

- 选中会话，按 Enter → WebView 窗口打开
- 查看器正确渲染 Markdown、代码高亮、工具调用块
- 大纲导航可点击跳转
- JS 发送 `copy` 消息，Lua 正确写入剪贴板

---

### 阶段 4：缓存与优化

**目标**：实现扫描缓存，提升搜索性能。

#### 4.1 缓存实现

**新建文件**: `plugins/cc-sessions/cache.lua`

- `lingxi.store` 存储扫描结果
- TTL 30 秒
- 提供 `get()` / `set()` / `clear()` 接口

#### 4.2 Git 工具

**新建文件**: `plugins/cc-sessions/git_utils.lua`

- 解析 `git remote` 获取项目名
- 解析 `git branch` 获取分支名

#### 4.3 缓存命令

**修改文件**: `plugins/cc-sessions/init.lua`

实现 `cmd_clear_cache(args)`：

```lua
function cmd_clear_cache(args)
    cache.clear()
    lingxi.alert.show("Cache cleared!", 2.0)
    return {{title = "Cache cleared", subtitle = "Session scan cache has been cleared"}}
end
```

#### 4.4 验证

- 首次搜索 → 扫描目录，耗时较长
- 再次搜索（30 秒内）→ 从缓存读取，瞬时响应
- 运行 `cc-sessions:clear-cache` → 缓存清除，下次重新扫描

---

### 阶段 5：测试与完善

**目标**：编写测试，处理边界情况。

#### 5.1 单元测试

**修改/新建**: `LingXiTests/` 相关测试文件

- WebView API 测试（模拟 JS 消息收发）
- Lua 插件搜索测试（验证 `search()` 返回格式）

#### 5.2 边界情况处理

- `~/.claude/projects/` 目录不存在 → 显示友好提示
- JSONL 文件损坏 → 跳过该文件，记录日志
- WebView 打开失败 → 回退到用默认程序打开 JSONL
- 消息数量过多 → 分页加载（后续优化）

#### 5.3 注册到插件市场

**修改文件**: `plugins/registry.toml`

```toml
[[plugins]]
id = "io.github.airead.lingxi.cc-sessions"
name = "Claude Code Sessions"
version = "1.0.0"
description = "Browse and view Claude Code session history"
author = "LingXi Team"
source = "https://raw.githubusercontent.com/Airead/LingXi/main/plugins/cc-sessions/plugin.toml"
min_lingxi_version = "1.1.0"
```

---

## 文件变更汇总

### 宿主端（Swift）

| 文件 | 类型 | 说明 |
|------|------|------|
| `LingXi/Plugin/PluginManifest.swift` | 修改 | `PermissionConfig` 新增 `webview: Bool` |
| `LingXi/Plugin/ManifestParser.swift` | 修改 | 解析 `permissions.webview` |
| `LingXi/Plugin/PluginManager.swift` | 修改 | 加载插件时注册 WebView 权限 |
| `LingXi/Plugin/LuaAPI.swift` | 修改 | 新增 `lingxi.webview.*` API 注册 |
| `LingXi/Plugin/PluginWebViewManager.swift` | **新建** | WebView 窗口管理器（单例） |
| `LingXi/Plugin/PluginWebViewWindow.swift` | **新建** | 单个 WKWebView 窗口实现 |
| `LingXiTests/LuaAPITests.swift` | 修改 | 新增 WebView API 测试 |

### 插件端（Lua + HTML）

| 文件 | 类型 | 说明 |
|------|------|------|
| `plugins/cc-sessions/plugin.toml` | **新建** | 插件元数据 |
| `plugins/cc-sessions/init.lua` | **新建** | 插件入口（search, 命令, 事件处理） |
| `plugins/cc-sessions/scanner.lua` | **新建** | 会话扫描器 |
| `plugins/cc-sessions/reader.lua` | **新建** | JSONL 读取与解析 |
| `plugins/cc-sessions/preview.lua` | **新建** | 文本预览生成 |
| `plugins/cc-sessions/cache.lua` | **新建** | 基于 lingxi.store 的缓存 |
| `plugins/cc-sessions/identicon.lua` | **新建** | SVG 项目头像生成 |
| `plugins/cc-sessions/git_utils.lua` | **新建** | Git 工具 |
| `plugins/cc-sessions/viewer.html` | **新建** | WebView 查看器 HTML |
| `plugins/cc-sessions/viewer.js` | **新建** | 查看器核心渲染逻辑 |
| `plugins/cc-sessions/vendor/marked.min.js` | **复制** | Markdown 渲染库 |
| `plugins/cc-sessions/vendor/highlight.min.js` | **复制** | 代码高亮库 |
| `plugins/cc-sessions/vendor/github-dark.min.css` | **复制** | 暗色代码主题 |
| `plugins/registry.toml` | 修改 | 注册 cc-sessions 插件 |

---

## 实现顺序

1. **阶段 1**：宿主端 WebView API（Swift）
2. **阶段 2**：插件骨架 + 扫描器（Lua）
3. **阶段 3**：预览 + 查看器（Lua + HTML/JS）
4. **阶段 4**：缓存与优化（Lua）
5. **阶段 5**：测试与完善

---

## 验证方式

### 单元测试

```bash
xcodebuild test -scheme LingXi -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LingXiTests
```

**需覆盖的测试**：
- `PluginWebViewManager`：打开/关闭窗口，消息收发
- `LuaAPI.webview`：Lua 调用 `open`/`close`/`send`/`on_message`
- `cc-sessions search()`：返回正确格式的 SearchResult
- `cc-sessions scanner`：正确扫描 `~/.claude/projects/` 目录

### 手动测试

- 呼出面板，输入 `cc` → 确认显示最近会话列表
- 输入 `cc 关键词` → 确认模糊匹配过滤
- 输入 `cc @项目名` → 确认按项目过滤
- 选中会话 → 确认右侧预览面板显示最近对话摘要
- 按 Enter → 确认 WebView 窗口打开，正确渲染 Markdown 和代码高亮
- WebView 中点击大纲 → 确认跳转到对应消息
- JS 发送 copy 消息 → 确认文本写入剪贴板
- 运行 `cc-sessions:clear-cache` → 确认缓存清除
- 重启 LingXi → 确认插件正常加载

---

## 回滚策略

每个阶段完成后立即 commit。验证失败时：
- 优先在当前阶段内修复
- 若宿主 WebView API 导致现有插件异常，立即回滚该阶段修改
- cc-sessions 插件本身可独立删除，不影响宿主功能

---

## 注意事项

1. **WebView 数量限制**：同一时间只允许一个插件 WebView 打开，避免资源竞争
2. **线程安全**：`PluginWebViewManager` 标记为 `@MainActor`，所有 UI 操作在主线程执行
3. **向后兼容**：`PermissionConfig` 新增 `webview` 字段后，旧插件 manifest 无此字段时默认为 `false`
4. **文件路径**：`~/.claude` 路径在不同用户环境一致，但需验证 `PathValidator` 是否支持 `~` 展开
5. **性能**：JSONL 文件可能很大（活跃会话可达数十 MB），MVP 先全量发送，后续优化为分页/按需加载
6. **测试隔离**：单元测试使用临时目录和 mock 数据，不读写真实 `~/.claude` 目录
7. **权限最小化**：cc-sessions 插件仅需 `filesystem`（读取 Claude 数据）、`clipboard`（复制文本）、`store`（缓存）、`webview`（查看器），其他权限均为 false
