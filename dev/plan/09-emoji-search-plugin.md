# Emoji 搜索插件实现计划

## 背景

为 LingXi 开发一个对标 WenZi `emoji_search` 插件的 Emoji 搜索功能。用户输入前缀（如 `e`）后，可搜索、浏览和粘贴 emoji，支持中英文关键词、分组筛选、预览面板等完整体验。

## 目标

1. **复刻 WenZi 核心体验**：前缀搜索、分组筛选（`@` 语法）、模糊匹配、直接粘贴
2. **扩展宿主能力**：为 Lua 插件系统增加 Paste、Modifier Action、Preview、Fuzzy Match、Tab Complete、Icon 等能力
3. **零外部依赖**：Emoji 数据复用 WenZi 的 `emoji-tree.json`，插件纯 Lua 实现
4. **向后兼容**：所有宿主扩展不影响现有插件

## WenZi 参考

| 文件 | 说明 |
|------|------|
| `/Users/fanrenhao/work/WenZi/plugins/emoji_search/__init__.py` | 核心实现（数据加载、搜索、预览 HTML、分组筛选、Tab 补全） |
| `/Users/fanrenhao/work/WenZi/plugins/emoji_search/plugin.toml` | 插件元数据 |
| `/Users/fanrenhao/work/WenZi/plugins/emoji_search/emoji-tree.json` | Emoji 数据（Unicode 分组、中英文名称） |
| `/Users/fanrenhao/work/WenZi/plugins/emoji_search/README.md` | 使用文档 |

## LingXi 现有代码

| 文件 | 说明 |
|------|------|
| `/Users/fanrenhao/work/LingXi/LingXi/Plugin/LuaSearchProvider.swift` | Lua 插件搜索提供者（解析 `search()` 结果，当前仅支持 title/subtitle/url/score/action） |
| `/Users/fanrenhao/work/LingXi/LingXi/Models/SearchResult.swift` | 搜索结果模型（含 `previewData`, `modifierActions`, `icon`, `actionContext` 等字段，但 Lua 层未暴露） |
| `/Users/fanrenhao/work/LingXi/LingXi/Search/FuzzyMatch.swift` | 宿主模糊匹配算法（`matchFields`） |
| `/Users/fanrenhao/work/LingXi/LingXi/Panel/PanelManager.swift` | 面板管理（`pasteAndActivate`, `previousApp`, `hidePanel`） |
| `/Users/fanrenhao/work/LingXi/LingXi/Plugin/LuaAPI.swift` | Lua API 注册中心（`lingxi.*` 模块注册） |
| `/Users/fanrenhao/work/LingXi/LingXi/Plugin/PluginManager.swift` | 插件加载、注册到 SearchRouter |
| `/Users/fanrenhao/work/LingXi/LingXi/UI/SearchViewModel.swift` | 搜索结果处理、确认逻辑、回调分发 |
| `/Users/fanrenhao/work/LingXi/plugins/api-showcase/init.lua` | 现有 Lua API 示例参考 |

---

## 设计决策

### D1: Paste API 设计

WenZi 提供 `wz.type_text(char, method="paste")` 实现选中即粘贴。LingXi 需新增 `lingxi.paste(text)` API：

- **实现方式**：调用 `PanelContext.pasteAndActivate()`，将文本写入剪贴板后模拟粘贴并切回前一应用
- **权限控制**：依赖 `clipboard = true`（已存在），无需新增权限类型
- **与 `lingxi.clipboard.write` 的区别**：`paste` 是"写入+粘贴+切回应用"的组合操作，`write` 仅写入剪贴板

### D2: Modifier Action 暴露方式

WenZi 支持 `secondary_action`（对应 Cmd+Enter）。LingXi 的 `SearchResult` 已有 `modifierActions: [ActionModifier: ModifierAction]`。

**方案**：在 Lua 结果表中支持可选字段：

```lua
{
    title = "😀",
    subtitle = "Grinning Face",
    action = function() lingxi.paste("😀") end,
    cmd_action = function() lingxi.clipboard.write("😀"); lingxi.alert("已复制", 1.2) end,
    cmd_subtitle = "Copy to clipboard"
}
```

`LuaSearchProvider` 解析时：
- 若存在 `cmd_action`，注册为 `.command` modifier action
- `cmd_subtitle` 作为 modifier action 的显示文本
- 同理可支持 `alt_action` / `alt_subtitle`、`ctrl_action` / `ctrl_subtitle`

### D3: Preview Data 格式

WenZi 使用 HTML 预览（大 emoji 显示、分组网格）。LingXi 的 `PreviewData` 当前仅支持 `.text(String)` 和 `.image(path:description:)`。

**方案**：扩展 `PreviewData` 新增 `.html(String)` case，或阶段性先用 `.text` 实现基础预览。

考虑到：
1. HTML 预览需要 WebView 组件，当前 LingXi 预览面板实现方式未知
2. WenZi 的 HTML 预览主要用于显示大 emoji 和分组网格，用纯文本也能表达核心信息

**决策**：
- **阶段 1-2**：先用 `.text` 预览，显示 emoji + 名称 + 分组信息
- **阶段 4**：如需要再扩展 `.html` 支持

### D4: Fuzzy Match API

WenZi 插件内调用 `fuzzy_match_fields()` 做搜索评分。LingXi 宿主已有 `FuzzyMatch.matchFields()`。

**方案**：暴露为 `lingxi.fuzzy.search(query, items, fields)`：

```lua
-- items: {{name = "cat", group = "animals"}, ...}
-- fields: {"name", "group"}
-- 返回: {{item = ..., score = 95}, ...}（已按 score 降序排序）
local results = lingxi.fuzzy.search("cat", emoji_records, {"name_en", "name_zh", "group_en", "group_zh"})
```

**替代方案**：插件内自带 Lua 模糊匹配算法（简单子串+距离计算），不依赖宿主。**决策**：先走宿主暴露方案，性能更好且与 WenZi 体验一致。如宿主扩展复杂度高，可 fallback 到插件自带算法。

### D5: Tab Complete

WenZi 支持 `complete(query, item)` 回调实现 Tab 补全（如 `@` 后按 Tab 补全分组名）。

**决策**：作为阶段 4 的增强功能，阶段 1-3 不实现。当前 LingXi 的 `FloatingPanel` 和 `SearchViewModel` 未处理 Tab 键事件，需要额外改动键盘事件链路和 Lua 回调机制。

### D6: Icon 支持

WenZi 为每个 emoji 结果生成 base64 SVG 图标。LingXi `SearchResult` 有 `icon: NSImage?`，但 `LuaSearchProvider` 硬编码为 `nil`。

**方案**：
- Lua 结果支持 `icon` 字段，值为字符串（emoji 字符或 base64 SVG）
- `LuaSearchProvider` 解析时，若 `icon` 是单字符 emoji，直接用该字符渲染为 NSImage
- 若 `icon` 以 `"data:image/svg+xml;base64,"` 开头，解码 base64 SVG 为 NSImage
- **简化**：Emoji 插件的结果 icon 就是 emoji 字符本身，无需 SVG，用字符直接生成 NSImage 即可

### D7: 数据加载方式

WenZi 的 `emoji-tree.json` 约 170KB，包含 3000+ emoji 的分层结构（group -> subgroup -> emoji）。

**决策**：
- 数据文件随插件分发，放在插件目录内
- Lua 通过 `lingxi.file.read()` 读取，用宿主提供的 JSON 解析（需确认 Lua 环境是否已有 json 库，如没有需暴露 `lingxi.json.parse`）
- 加载时构建三个索引：
  1. `records` — 扁平列表（所有 emoji dict）
  2. `group_map` — 分组名 -> emoji 列表映射
  3. `groups` — 顶层分组元数据列表

### D8: 搜索行为

复刻 WenZi 的三层搜索逻辑：

1. **空查询 / 仅 `@`** → 显示所有分组列表（每个分组一个结果项）
2. **`@分组名`** → 显示该分组下的所有 emoji
3. **`关键词 @分组名`** → 在指定分组内搜索关键词
4. **`关键词`** → 全局模糊搜索

分组筛选使用精确匹配 + 模糊回退（与 WenZi 一致）。

---

## 实现阶段

### 阶段 1：Paste API + Icon 支持

**目标**：实现最核心的"选中即粘贴"体验，以及 emoji 结果的图标显示。

#### 1.1 新增 `lingxi.paste(text)` API

**修改文件**: `LingXi/Plugin/LuaAPI.swift`

在 `registerClipboard` 或新增 `registerPaste` 函数中：

```swift
// lingxi.paste(text) -> boolean
// 1. 写入剪贴板
// 2. 调用 PanelContext.pasteAndActivate()
// 3. 返回是否成功
```

**实现细节**：
- 需要 LuaAPI 持有 `PanelContext` 引用（或通过 PluginManager 间接获取）
- 检查 `permissions.clipboard` 为 true 时才注册此 API
- 内部实现：
  ```swift
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  pasteboard.setString(text, forType: .string)
  // 模拟 Cmd+V 粘贴
  // 切回前一应用
  ```

#### 1.2 `LuaSearchProvider` 支持 `icon` 字段

**修改文件**: `LingXi/Plugin/LuaSearchProvider.swift`

在 `parseOneResult` 中：

```swift
let iconString = state.stringField("icon", at: index)
let icon: NSImage? = iconString.flatMap { string in
    // 若字符串是单个 emoji 字符，生成 NSImage
    // 若字符串是 base64 SVG，解码为 NSImage
    // 否则 nil
}
```

创建 `emojiIcon(from: String) -> NSImage?` 辅助函数：
- 用 `NSAttributedString` 渲染字符到 `NSImage`
- 尺寸与现有搜索结果图标一致（约 32x32）

#### 1.3 验证

创建测试插件：

```lua
function search(query)
    return {{
        title = "😀",
        subtitle = "Test paste",
        icon = "😀",
        action = function()
            lingxi.paste("😀")
        end
    }}
end
```

- 确认选中后文本被粘贴到前一应用
- 确认 emoji 图标在结果列表中正确显示

---

### 阶段 2：Modifier Action + Preview Data

**目标**：实现 Cmd+Enter 复制到剪贴板，以及右侧预览面板。

#### 2.1 `LuaSearchProvider` 支持 Modifier Action

**修改文件**: `LingXi/Plugin/LuaSearchProvider.swift`

在 `parseOneResult` 中解析 modifier action 字段：

```swift
// 解析 cmd_action
state.getField("cmd_action", at: index)
if state.isFunction(at: -1) {
    let ref = state.ref(at: -1)
    let cmdSubtitle = state.stringField("cmd_subtitle", at: index) ?? ""
    result.modifierActions[.command] = ModifierAction(subtitle: cmdSubtitle) { _ in
        Task {
            await self.executeAction(ref: ref)
        }
        return true
    }
} else {
    state.pop()
}
```

同理支持 `alt_action` / `alt_subtitle`（Option）、`ctrl_action` / `ctrl_subtitle`（Control）。

**Action 执行**：复用现有的 `executeAction(ref:)` 方法。

#### 2.2 `LuaSearchProvider` 支持 `preview` 字段

**修改文件**: `LingXi/Plugin/LuaSearchProvider.swift`

```swift
let previewType = state.stringField("preview_type", at: index) // "text" | "html"
let previewContent = state.stringField("preview", at: index)

if previewType == "text", let content = previewContent {
    result.previewData = .text(content)
}
// 后续阶段支持 "html"
```

同时修改 `supportsPreview`：

```swift
nonisolated var supportsPreview: Bool { true }
```

#### 2.3 `SearchViewModel` 确保 `.command` 类型也显示预览

**检查文件**: `LingXi/UI/SearchViewModel.swift`

确认 `confirm()` 和预览逻辑对 `.command` 类型的处理方式。如有需要，确保 `.command` 类型结果能显示 previewData。

#### 2.4 验证

```lua
function search(query)
    return {{
        title = "😀",
        subtitle = "Grinning Face",
        icon = "😀",
        action = function() lingxi.paste("😀") end,
        cmd_action = function() 
            lingxi.clipboard.write("😀") 
            lingxi.alert("已复制", 1.2)
        end,
        cmd_subtitle = "Copy to clipboard",
        preview_type = "text",
        preview = "😀\nGrinning Face\n微笑"
    }}
end
```

- 确认右侧显示预览文本
- 确认 Cmd+Enter 触发复制并显示 alert

---

### 阶段 3：Fuzzy Match API + JSON 解析

**目标**：让插件可以使用宿主的高性能模糊匹配，并能解析 JSON 数据文件。

#### 3.1 暴露 `lingxi.fuzzy.search`

**新建文件**: `LingXi/Plugin/LuaFuzzyAPI.swift`（或在 LuaAPI.swift 中新增）

```swift
// lingxi.fuzzy.search(query, items, fields) -> {{item = ..., score = number}, ...}
// 
// items: Lua table array，每个元素是 dict
// fields: Lua table array，指定要匹配的字段名
// 返回：按 score 降序排列的结果数组
```

**实现方式**：
1. 从 Lua 栈读取 `items`（table array）和 `fields`（string array）
2. 转换为 Swift `[[String: String]]` 和 `[String]`
3. 对每个 item，用 `FuzzyMatch.matchFields(query, fieldValues)` 计算 score
4. 过滤掉未匹配的，按 score 排序
5. 将结果写回 Lua 栈（table array，每个元素含 `item` 和 `score`）

**边界处理**：
- `items` 为空数组 → 返回空数组
- `fields` 中的字段在 item 中不存在 → 视为空字符串参与匹配
- 大数据量时的性能：emoji 数据约 3000+ 条，宿主模糊匹配应能轻松处理

#### 3.2 暴露 `lingxi.json.parse`

**检查/修改文件**: `LingXi/Plugin/LuaAPI.swift`

确认 Lua 环境是否已有 JSON 库（如 `dkjson` 或 Lua 5.4 内置）。如没有，新增：

```swift
// lingxi.json.parse(json_string) -> table | nil
// 将 JSON 字符串解析为 Lua table
```

使用 `JSONSerialization` 实现，支持 dict/array/string/number/boolean/null。

#### 3.3 验证

```lua
function search(query)
    local items = {
        {name = "cat", group = "animals"},
        {name = "dog", group = "animals"},
        {name = "apple", group = "food"}
    }
    local results = lingxi.fuzzy.search("ca", items, {"name", "group"})
    -- 预期返回 {{item = {name = "cat", ...}, score = 100}, ...}
    
    return {{
        title = "Fuzzy test",
        subtitle = "Found " .. #results .. " results",
        action = function() end
    }}
end
```

---

### 阶段 4：Emoji 插件实现

**目标**：创建完整的 emoji 搜索插件。

#### 4.1 插件目录结构

```
plugins/emoji-search/
├── plugin.toml
├── init.lua
└── emoji-tree.json    (从 WenZi 复制)
```

#### 4.2 `plugin.toml`

```toml
[plugin]
id = "io.github.airead.lingxi.emoji-search"
name = "Emoji Search"
description = "Search and paste emoji via the launcher (prefix: e)"
version = "1.0.0"
author = "LingXi Team"
url = "https://github.com/Airead/LingXi"
min_lingxi_version = "1.0.0"

files = [
    "init.lua",
    "emoji-tree.json",
    "README.md",
]

[search]
prefix = "e"
debounce = 50
timeout = 10000

[permissions]
network = false
clipboard = true
filesystem = ["~/.config/LingXi/plugins/io.github.airead.lingxi.emoji-search/"]
store = false
notify = false
shell = []
```

#### 4.3 `init.lua` 核心逻辑

参考 WenZi `__init__.py` 实现，分以下模块：

**数据加载模块**：
- 使用 `lingxi.file.read()` 读取 `emoji-tree.json`
- 使用 `lingxi.json.parse()` 解析
- 构建 `records`（扁平列表）、`group_map`（分组映射）、`groups`（分组元数据）

**查询解析模块**：
- `_parse_query(query, group_map)`：解析 `@分组名` 语法
- 从后往前匹配，支持精确匹配和模糊匹配
- 返回 `(keyword, group_filter)`

**搜索模块**：
- `_search_emojis(query, records, group_map)`：
  1. 空查询 / 仅 `@` → 返回分组列表
  2. 有分组筛选 → 用 `lingxi.fuzzy.search` 在分组内搜索
  3. 无分组 → 全局模糊搜索
- 限制结果数量（默认 30，分组模式 200）

**结果构建模块**：
- `_emoji_item(rec)`：构建单个 emoji 结果
  - `title` = emoji 字符
  - `subtitle` = `中文名 | 英文名 · 分组`
  - `icon` = emoji 字符
  - `action` = `lingxi.paste(emoji)`
  - `cmd_action` = `lingxi.clipboard.write(emoji) + lingxi.alert("已复制", 1.2)`
  - `cmd_subtitle` = "Copy to clipboard"
  - `preview_type` = "text"
  - `preview` = 格式化文本（大 emoji + 名称 + 分组）

- `_group_item(g)`：构建分组结果
  - `title` = 分组中文名（或英文名）
  - `subtitle` = 分组英文名
  - `icon` = 分组第一个 emoji
  - `action` = 粘贴第一个 emoji
  - `preview_type` = "text"
  - `preview` = 分组内所有 emoji 的列表

**主 `search(query)` 函数**：

```lua
function search(query)
    query = query or ""
    query = query:gsub("^%s*e%s*", ""):gsub("^%s*", "")
    
    if query == "@" then
        -- 显示所有分组
        return group_items()
    end
    
    local results = _search_emojis(query, records, group_map)
    return emoji_items(results)
end
```

#### 4.4 验证

- 输入 `e` → 显示分组列表
- 输入 `e cat` → 搜索含 "cat" 的 emoji
- 输入 `e @动物与自然` → 显示"动物与自然"分组下的 emoji
- 输入 `e face @表情与情感` → 在"表情与情感"分组内搜索 "face"
- 选中 emoji → 直接粘贴到前一应用
- Cmd+Enter → 复制到剪贴板并显示提示
- 右侧预览面板显示 emoji 详情

---

### 阶段 5：Tab Complete（可选增强）

**目标**：实现 `@` 后的 Tab 补全。

#### 5.1 宿主 Tab Complete 机制

**需修改的文件**：
- `LingXi/UI/SearchViewModel.swift`：处理 Tab 键事件
- `LingXi/Panel/PanelManager.swift`：监听 Tab 键
- `LingXi/Plugin/LuaSearchProvider.swift`：调用 Lua `complete(query, selectedItem)`

**实现方式**：
1. `FloatingPanel` 捕获 Tab 键事件，发送给 `SearchViewModel`
2. `SearchViewModel` 判断当前选中项的来源是否为 Lua 插件
3. 若是，调用对应 provider 的 `tabComplete(query:selectedItem:)`
4. `LuaSearchProvider` 调用 Lua 全局函数 `complete(query, item_title)`
5. 若 Lua 返回字符串，替换当前 query 为该字符串

#### 5.2 Emoji 插件 Tab Complete

在 `init.lua` 中：

```lua
function complete(query, item_title)
    if query:match("^%s*@") then
        -- 补全分组名
        return "@" .. item_title .. " "
    end
    return nil
end
```

#### 5.3 决策

此阶段依赖较多宿主改动（键盘事件链路至 Lua 回调），优先级低于前 4 个阶段。建议作为独立任务，在核心功能稳定后再实现。

---

### 阶段 6：HTML Preview（可选增强）

**目标**：实现 WenZi 式的富文本预览（大 emoji 显示、分组网格）。

#### 6.1 扩展 `PreviewData`

**修改文件**: `LingXi/Models/SearchResult.swift`

```swift
enum PreviewData: Sendable {
    case text(String)
    case image(path: URL, description: String)
    case html(String)  // 新增
}
```

#### 6.2 预览面板支持 HTML

**需确认/修改的文件**：
- `LingXi/Panel/PanelManager.swift` 或相关 Preview 视图
- 若预览面板使用 `NSTextView` → 需替换/扩展为 `WKWebView`
- 若预览面板使用 SwiftUI `Text` → 需扩展为支持 `AttributedString` 或 `WebView`

**简化方案**：先用 `.text` 配合 Unicode 和换行符模拟布局，避免引入 WebView 依赖。

#### 6.3 决策

HTML Preview 是锦上添花功能，建议：
- 阶段 1-4 先用 `.text` 预览
- 阶段 6 评估是否有必要引入 WebView，以及实现成本
- 如 LingXi 预览面板已支持富文本/AttributedString，可用其替代 HTML

---

## 文件变更汇总

| 文件 | 类型 | 说明 |
|------|------|------|
| `LingXi/Plugin/LuaAPI.swift` | 修改 | 新增 `lingxi.paste`、`lingxi.fuzzy.search`、`lingxi.json.parse` |
| `LingXi/Plugin/LuaSearchProvider.swift` | 修改 | 支持 `icon`、`preview_type`/`preview`、`cmd_action`/`cmd_subtitle` 等 modifier action 字段；`supportsPreview = true` |
| `LingXi/Models/SearchResult.swift` | 修改 | 新增 `PreviewData.html`（阶段 6） |
| `LingXi/UI/SearchViewModel.swift` | 修改 | 确保 `.command` 类型结果支持 previewData 和 modifierActions（如需要） |
| `LingXi/Panel/PanelManager.swift` | 修改 | 为 `lingxi.paste` 提供 `PanelContext` 支持 |
| `LingXiTests/LuaSearchProviderTests.swift` | **新建/修改** | 新增 modifier action、icon、preview 字段解析测试 |
| `plugins/emoji-search/plugin.toml` | **新建** | Emoji 插件元数据 |
| `plugins/emoji-search/init.lua` | **新建** | Emoji 插件核心逻辑 |
| `plugins/emoji-search/emoji-tree.json` | **新建** | Emoji 数据（从 WenZi 复制） |
| `plugins/emoji-search/README.md` | **新建** | 插件使用文档 |
| `plugins/registry.toml` | 修改 | 注册 emoji-search 插件 |

---

## 实现顺序

1. **阶段 1**：Paste API + Icon 支持（核心体验）
2. **阶段 2**：Modifier Action + Preview Data（次选操作、预览面板）
3. **阶段 3**：Fuzzy Match API + JSON 解析（搜索能力、数据加载）
4. **阶段 4**：Emoji 插件实现（完整功能验证）
5. **阶段 5**：Tab Complete（可选，独立任务）
6. **阶段 6**：HTML Preview（可选，评估后决定）

---

## 验证方式

### 单元测试

```bash
xcodebuild test -scheme LingXi -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LingXiTests
```

**需覆盖的测试**：
- `LuaSearchProvider.parseOneResult`：解析 `icon`、`preview_type`/`preview`、`cmd_action`/`cmd_subtitle`
- `lingxi.paste`：文本被写入剪贴板并触发粘贴
- `lingxi.fuzzy.search`：正确返回匹配项和分数
- `lingxi.json.parse`：正确解析 JSON 为 Lua table

### 手动测试

- 呼出面板，输入 `e` → 确认显示 emoji 分组列表
- 输入 `e cat` → 确认搜索到 🐱 等相关 emoji
- 输入 `e @动物与自然` → 确认只显示动物分组
- 选中 emoji → 确认直接粘贴到前一应用
- Cmd+Enter → 确认复制到剪贴板并显示 "已复制" 提示
- 右侧预览面板 → 确认显示 emoji 名称和分组信息
- 输入 `e face @表情` → 确认在表情分组内搜索 "face"
- 重启 LingXi → 确认插件和数据正常加载

---

## 回滚策略

每个阶段完成后立即 commit。验证失败时：
- 优先在当前阶段内修复
- 若宿主扩展导致现有插件异常，立即回滚该阶段修改
- Emoji 插件本身可独立删除，不影响宿主功能

---

## 注意事项

1. **并发安全**：`lingxi.paste` 涉及剪贴板和前端应用切换，必须在 `@MainActor` 执行。Lua 回调通过 `Task { @MainActor in ... }` 确保在主线程执行。
2. **向后兼容**：`LuaSearchProvider` 解析新字段时使用安全访问（`stringField` 返回 nil 时不影响其他字段），确保旧插件继续工作。
3. **性能**：emoji 数据约 3000+ 条，宿主模糊匹配应能轻松处理。如性能有问题，考虑在 Lua 端缓存索引。
4. **测试隔离**：单元测试使用临时目录和 mock 数据，不读写真实插件目录。
5. **权限最小化**：emoji 插件仅需 `clipboard = true`，其他权限均为 false。
