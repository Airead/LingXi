# CommandSearchProvider 实现计划

## 背景

LingXi 已有完整的搜索系统（SearchProvider + SearchRouter + FuzzyMatch）。需要复刻 WenZi 的 CommandSource，实现命令面板功能：用户输入 `> ` 前缀进入命令模式，支持模糊搜索、参数传递（args 模式）、promoted 命令（无前缀也能搜到）。

## WenZi 参考代码

| 文件 | 说明 |
|------|------|
| `/Users/fanrenhao/work/WenZi/src/wenzi/scripting/sources/command_source.py` | 命令源核心实现（CommandEntry, CommandSource, 三模搜索, Tab 补全, promoted） |
| `/Users/fanrenhao/work/WenZi/src/wenzi/scripting/sources/__init__.py` | 基础数据结构（ChooserItem, ChooserSource, fuzzy_match_fields, ModifierAction） |
| `/Users/fanrenhao/work/WenZi/src/wenzi/scripting/api/chooser.py` | 命令注册 API（register_command, @command 装饰器, 内置命令 quit-all/help/reload/settings） |
| `/Users/fanrenhao/work/WenZi/tests/scripting/test_command_source.py` | 测试（295行, 覆盖名称验证/搜索模式/action/补全/promoted/ChooserSource） |

## LingXi 现有代码

| 文件 | 说明 |
|------|------|
| `/Users/fanrenhao/work/LingXi/LingXi/Search/SearchProvider.swift` | SearchProvider 协议 + scoredItems 辅助方法 |
| `/Users/fanrenhao/work/LingXi/LingXi/Models/SearchResult.swift` | SearchResult 结构体（`.command` 类型已定义但未使用）、ModifierAction、ActionModifier |
| `/Users/fanrenhao/work/LingXi/LingXi/Search/FuzzyMatch.swift` | FuzzyMatch.matchFields() 模糊匹配 |
| `/Users/fanrenhao/work/LingXi/LingXi/Search/SearchRouter.swift` | 前缀路由、registerDefault() 注册无前缀 provider |
| `/Users/fanrenhao/work/LingXi/LingXi/Search/SnippetSearchProvider.swift` | actor-based provider 模板（注册、搜索、makeResult 模式） |
| `/Users/fanrenhao/work/LingXi/LingXi/UI/SearchViewModel.swift` | confirm() 处理各类型结果、onClipboardPaste/onSnippetPaste 回调模式 |
| `/Users/fanrenhao/work/LingXi/LingXi/Panel/PanelManager.swift` | provider 创建与 router 注册、回调设置 |
| `/Users/fanrenhao/work/LingXi/LingXi/Settings/AppSettings.swift` | 设置属性模式（enabled + prefix + Key 枚举 + didSet 持久化） |
| `/Users/fanrenhao/work/LingXi/LingXi/Screenshot/ScreenshotManager.swift` | captureRegion() (L18), captureFullScreen() (L99) |
| `/Users/fanrenhao/work/LingXi/LingXi/Search/ClipboardStore.swift` | imageDirectory 静态属性 (L70-81), 路径: `~/Library/Application Support/LingXi/clipboard_images/` |
| `/Users/fanrenhao/work/LingXi/LingXi/Search/SnippetStore.swift` | defaultDirectory 静态属性 (L38-42), 路径: `~/.config/LingXi/snippets/` |
| `/Users/fanrenhao/work/LingXi/LingXi/Settings/SettingsWindowManager.swift` | `SettingsWindowManager.shared.show()` 打开设置窗口 |
| `/Users/fanrenhao/work/LingXi/LingXi/LingXiApp.swift` | AppDelegate.showSettings() (L195-197), 截图热键注册 (L87-98) |
| `/Users/fanrenhao/work/LingXi/LingXiTests/SnippetSearchProviderTests.swift` | Swift Testing 测试模板 |
| `/Users/fanrenhao/work/LingXi/LingXiTests/SearchViewModelTests.swift` | SearchViewModel 测试模板（MockSearchProvider, waitUntil） |

## 设计决策

### D1: 命令 action 如何在 SearchViewModel 中执行

采用与 `onClipboardPaste` / `onSnippetPaste` 一致的回调模式：

- `SearchResult` 新增 `actionContext: String` 字段存储 args
- `SearchViewModel` 新增 `onCommandExecute: ((SearchResult) -> Void)?` 回调
- `confirm()` 中 `.command` 类型调用此回调
- `PanelManager` 设置回调，通过 `CommandSearchProvider.entry(for:)` 查找命令并执行 action

### D2: quit 命令如何工作

args 模式：用户输入 `> quit Safari`，action 闭包接收 "Safari"，遍历 `NSWorkspace.shared.runningApplications` 匹配 `localizedName` 后调用 `terminate()`。首期不做运行中 app 列表展示，仅按名称匹配。

参考 WenZi 实现: `/Users/fanrenhao/work/WenZi/src/wenzi/scripting/api/chooser.py` L149-175

### D3: help 命令

简化方案：`help` 命令直接打开设置窗口，subtitle 显示所有可用前缀的摘要文本（如 `"> commands, f files, cb clipboard, sn snippets, ..."`）。前缀配置在设置中管理，打开设置窗口是最直接的帮助方式。

### D4: Tab 补全

暂不实现。当前 `FloatingPanel` 未处理 Tab 键事件，添加 Tab 补全需要改动 FloatingPanel -> SearchViewModel -> SearchRouter 整条链路，作为后续独立功能。

### D5: Promoted 命令

注册两个 provider 到 SearchRouter：

- `"command"` — 带前缀 `">"`, 完整命令搜索（含 args 模式）
- `"command-promoted"` — 无前缀, 通过 `registerDefault()` 注册，仅搜索 promoted 命令

`PromotedCommandSearchProvider` 作为薄包装，委托给 `CommandSearchProvider.promotedSearch()`。

### D6: CommandEntry 的 Sendable 问题

`CommandEntry` 包含 `NSImage?`（非 Sendable）。标记为 `@unchecked Sendable`，与现有 `SearchResult` 处理方式一致。icon 字段只读，实际线程安全。

### D7: action 签名

`@MainActor @Sendable (String) async -> Void`，接收 args 字符串。使用 async 以支持 `ScreenshotManager.shared.captureRegion()` 等异步操作。

## 实现步骤

### Step 1: SearchResult 添加 actionContext

**修改文件**: `LingXi/Models/SearchResult.swift`

在 `SearchResult` struct 中添加：

```swift
var actionContext: String = ""
```

默认空字符串，不影响现有代码。

### Step 2: 创建 CommandSearchProvider

**新建文件**: `LingXi/Search/CommandSearchProvider.swift`

核心结构：

```
CommandEntry (struct, @unchecked Sendable)
├── name: String              — 唯一标识（正则验证）
├── title: String             — 显示标题
├── subtitle: String          — 描述
├── icon: NSImage?            — 图标（SF Symbol）
├── action: @MainActor @Sendable (String) async -> Void  — 执行回调
└── promoted: Bool            — 是否在无前缀搜索中出现

CommandSearchProvider (actor, SearchProvider)
├── register(_ entry:) throws — 注册命令（名称验证）
├── unregister(_ name:)       — 注销命令
├── clear()                   — 清空所有命令
├── search(query:) async      — 三模搜索（列表/args/模糊）
├── promotedSearch(query:)    — 仅搜索 promoted 命令
├── entry(for itemId:)        — 按 itemId 查找命令（供 PanelManager 用）
└── makeResult(entry:args:score:) — 构建 SearchResult（nonisolated）

CommandError (enum, Error)
└── invalidName(String)
```

**名称验证正则**: `^[a-zA-Z0-9][a-zA-Z0-9_:\-]*$`

**搜索逻辑**（对应 WenZi `command_source.py` L82-113 的 `search()` 方法）：

1. 空查询 -> 返回所有命令，按 name 排序，score=50
2. query 含空格且首词精确匹配命令名 -> args 模式，返回单个结果，score=100，`actionContext` 为 args 部分
3. 否则 -> 用 `scoredItems(from:query:names:)` 模糊匹配 title+name

**itemId 格式**: `"cmd:{name}"`

**promoted 搜索**（对应 WenZi `command_source.py` L131-147 的 `promoted_search()` 方法）：

- 空查询返回空（不同于普通搜索返回全部）
- 仅搜索 `promoted == true` 的命令
- 不支持 args 模式，纯模糊搜索

### Step 3: 创建 PromotedCommandSearchProvider

**新建文件**: `LingXi/Search/PromotedCommandSearchProvider.swift`

薄包装 actor，持有 `CommandSearchProvider` 引用，`search()` 委托给 `commandProvider.promotedSearch(query:)`。

### Step 4: 编写测试

**新建文件**: `LingXiTests/CommandSearchProviderTests.swift`

使用 Swift Testing 框架（`import Testing`, `@Test`, `#expect`）。

测试用例（对应 WenZi `test_command_source.py` 的测试结构）：

**名称验证** (`test_command_source.py` L14-48 TestCommandEntry):
- 有效名称: `reload-scripts`, `cc-sessions:clear-cache`, `reload_scripts`
- 无效名称: 含空格, 空字符串, 以连字符开头
- 重复注册覆盖旧命令

**搜索模式** (`test_command_source.py` L51-129 TestCommandSourceSearch):
- 空查询返回所有命令，按 name 排序
- 模糊匹配 title
- 模糊匹配 name
- 无匹配返回空
- args 模式: 精确命令名 + 空格 -> 单结果，actionContext 包含 args
- args 模式: 空 args（`"greet "`）
- args 模式: 首词不精确匹配 -> 降级为模糊搜索
- 前导空格被 trim
- itemId 以 `"cmd:"` 开头

**注册/注销** (`test_command_source.py` L208-224 TestCommandSourceUnregister):
- unregister 后搜索不到
- unregister 不存在的命令不报错
- clear 后为空

**Promoted 搜索** (`test_command_source.py` L227-274 TestCommandSourcePromoted):
- 仅返回 promoted 命令
- 空查询返回空
- 不支持 args 模式
- promoted 命令在带前缀搜索中也出现

**Result 属性**:
- resultType 为 `.command`
- extractName 工具方法正确

### Step 5: SearchViewModel 处理 .command 类型

**修改文件**: `LingXi/UI/SearchViewModel.swift`

1. 添加回调属性（与 `onClipboardPaste` 并列，约 L29）：

```swift
var onCommandExecute: ((SearchResult) -> Void)?
```

2. 在 `confirm()` 方法中（约 L95），modifierAction 检查之后、pasteHandler 之前，插入：

```swift
if selected.resultType == .command {
    onCommandExecute?(selected)
    recordExecution(query: currentQuery, itemId: selected.itemId)
    return true
}
```

### Step 6: AppSettings 添加命令搜索设置

**修改文件**: `LingXi/Settings/AppSettings.swift`

添加属性（参考现有 snippet 设置模式 L243-245）：

- `commandSearchEnabled: Bool`（默认 `true`）+ `didSet` 持久化
- `commandSearchPrefix: String`（默认 `">"`）+ `didSet` 持久化

添加对应 Key 枚举值：

- `case commandSearchEnabled = "io.github.airead.lingxi.commandSearchEnabled"`
- `case commandSearchPrefix = "io.github.airead.lingxi.commandSearchPrefix"`

### Step 7: PanelManager 集成

**修改文件**: `LingXi/Panel/PanelManager.swift`

#### 7.1 添加实例属性

```swift
private let commandProvider: CommandSearchProvider
```

#### 7.2 在 init(settings:) 中创建并注册

在 snippetStore 创建之后、router 注册到 viewModel 之前，创建 `CommandSearchProvider` 并注册内置命令：

| 命令名 | 标题 | icon (SF Symbol) | action | promoted |
|--------|------|-------------------|--------|----------|
| `settings` | Open Settings | `gear` | `SettingsWindowManager.shared.show()` | true |
| `help` | Show Help | `questionmark.circle` | `SettingsWindowManager.shared.show()` | false |
| `screenshot` | Capture Region | `camera.viewfinder` | `await ScreenshotManager.shared.captureRegion()` | false |
| `screenshot-fullscreen` | Capture Full Screen | `camera` | `await ScreenshotManager.shared.captureFullScreen()` | false |
| `reveal-clipboard-images` | Reveal Clipboard Images | `photo.on.rectangle` | `NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ClipboardStore.imageDirectory.path)` | false |
| `reveal-snippets` | Reveal Snippets Folder | `folder` | `NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: SnippetStore.defaultDirectory.path)` | false |
| `quit` | Quit Application | `xmark.circle` | 按 args 匹配 `NSWorkspace.shared.runningApplications` 的 `localizedName`，`terminate()` 匹配的 app | false |
| `quit-all` | Quit All Applications | `xmark.circle.fill` | 遍历 `runningApplications`，跳过 `activationPolicy != .regular`、Finder(`com.apple.finder`)、自身(`Bundle.main.bundleIdentifier`)，`terminate()` 其余 | false |

注册到 router：

```swift
router.register(prefix: settings.commandSearchPrefix, id: "command", provider: commandProvider)
let promotedProvider = PromotedCommandSearchProvider(commandProvider: commandProvider)
router.registerDefault(id: "command-promoted", provider: promotedProvider)
```

#### 7.3 设置 onCommandExecute 回调

```swift
viewModel.onCommandExecute = { [weak self] result in
    guard let self else { return }
    Task {
        guard let entry = await self.commandProvider.entry(for: result.itemId) else { return }
        await entry.action(result.actionContext)
    }
}
```

#### 7.4 在 applySettings() 中处理

```swift
router.setEnabled(settings.commandSearchEnabled, forId: "command")
router.setEnabled(settings.commandSearchEnabled, forId: "command-promoted")
router.updatePrefix(settings.commandSearchPrefix, forId: "command")
```

## 文件变更汇总

| 文件 | 类型 | 说明 |
|------|------|------|
| `LingXi/Models/SearchResult.swift` | 修改 | 添加 `actionContext: String` |
| `LingXi/Search/CommandSearchProvider.swift` | **新建** | CommandEntry + CommandSearchProvider + CommandError |
| `LingXi/Search/PromotedCommandSearchProvider.swift` | **新建** | Promoted 命令搜索薄包装 |
| `LingXiTests/CommandSearchProviderTests.swift` | **新建** | 全面测试 |
| `LingXi/UI/SearchViewModel.swift` | 修改 | 添加 `onCommandExecute` 回调和 `.command` 处理 |
| `LingXi/Settings/AppSettings.swift` | 修改 | 添加 commandSearchEnabled / commandSearchPrefix 设置 |
| `LingXi/Panel/PanelManager.swift` | 修改 | 注册 provider、内置命令、回调、applySettings |

## 实现顺序

1. `SearchResult.swift` — 添加 actionContext（零影响）
2. `CommandSearchProvider.swift` — 核心实现（可独立编译）
3. `PromotedCommandSearchProvider.swift` — promoted 包装
4. `CommandSearchProviderTests.swift` — 测试，确保核心逻辑正确
5. `SearchViewModel.swift` — 添加 `.command` 处理
6. `AppSettings.swift` — 添加设置项
7. `PanelManager.swift` — 集成所有组件

## 验证方式

### 单元测试

```bash
xcodebuild test -scheme LingXi -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LingXiTests
```

### 手动测试

- 呼出面板，输入 `> ` 确认显示所有 8 个命令
- 输入 `> set` 确认模糊匹配到 Open Settings
- 输入 `> screenshot` 回车，确认触发区域截图
- 输入 `> quit Safari` 回车，确认退出 Safari
- 输入 `> quit-all` 回车，确认退出所有应用（Finder 和自身除外）
- 输入 `> reveal-` 确认两个 reveal 命令出现
- 不输入前缀，直接搜 `settings` 确认 promoted 命令出现在结果中
