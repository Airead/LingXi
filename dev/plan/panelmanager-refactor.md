# PanelManager Provider 模块化重构计划

## 目标

将 PanelManager 中硬编码的 Provider 注册逻辑和 Store 管理提取为独立的 Module，使新增 Provider 无需修改 PanelManager。

## 最终架构

```
AppAssembly (Composition Root)
├── PluginManager (独立全局服务，实现 PluginService 协议)
└── PanelManager (只负责面板生命周期)
    ├── SearchRouter
    ├── SearchViewModel
    └── modules: [SearchProviderModule]
        ├── ClipboardModule
        ├── SnippetModule
        ├── CommandModule
        ├── FileSearchModule
        ├── BookmarkModule
        ├── SystemSettingsModule
        └── ApplicationModule
```

## 阶段 1：提取 PluginService 协议

### 工作内容

1. 创建 `LingXi/Plugin/PluginService.swift`：
   ```swift
   protocol PluginService: Sendable {
       func dispatchEvent(name: String, data: [String: String]) async
   }
   ```
2. 让 `PluginManager` 实现 `PluginService`。
3. 修改 PanelManager 的 `init`，将 `pluginManager` 参数类型从 `PluginManager` 改为 `PluginService`（目前仅用于事件分发的部分）。

### 验证方法

1. 编译通过，无报错。
2. 运行现有测试：`xcodebuild test -scheme LingXi -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LingXiTests`
3. 启动应用，确认插件系统正常工作（如 `plugin:list` 命令可用）。

## 阶段 2：定义核心协议

### 工作内容

1. 创建 `LingXi/Panel/SearchProviderModule.swift`：
   ```swift
   @MainActor
   protocol SearchProviderModule {
       var moduleId: String { get }
       func register(router: SearchRouter, settings: AppSettings)
       func applySettings(_ settings: AppSettings, router: SearchRouter)
       func bindEvents(to viewModel: SearchViewModel, context: PanelContext)
       func start()
       func stop()
   }
   ```
2. 创建 `LingXi/Panel/PanelContext.swift`：
   ```swift
   @MainActor
   protocol PanelContext: AnyObject {
       var previousApp: NSRunningApplication? { get }
       func pasteAndActivate()
       func hidePanel()
   }
   ```
3. 为协议提供默认空实现（`extension SearchProviderModule`），避免每个模块都写空方法。
4. 创建 `LingXi/Panel/PluginAwareModule.swift`：
   ```swift
   @MainActor
   protocol PluginAwareModule {
       func afterPluginsLoaded() async
   }
   ```

### 验证方法

1. 编译通过，无报错。
2. 检查代码：确认 PanelContext 协议定义完整，包含所有需要暴露给模块的面板操作。

## 阶段 3：提取 ClipboardModule

### 工作内容

1. 创建 `LingXi/Panel/Modules/ClipboardModule.swift`：
   - 封装 `ClipboardStore`
   - 在 `register()` 中注册 `ClipboardHistoryProvider`
   - 在 `bindEvents()` 中处理 `onDeleteItem` 和 `onClipboardPaste`
   - 在 `applySettings()` 中管理监控启停和容量
2. 修改 `PanelManager`：
   - 移除 `clipboardStore` 属性
   - 移除剪贴板相关的 `router.register()` 调用
   - 移除 `viewModel.onDeleteItem` 和 `viewModel.onClipboardPaste` 的赋值
   - 移除 `applySettings()` 中的剪贴板相关逻辑
   - 在 `init` 中接收 `ClipboardModule` 实例

### 验证方法

1. **基础搜索**：输入剪贴板搜索前缀，确认能搜索到历史记录。
2. **粘贴功能**：选择一个剪贴板项目，按回车，确认内容被粘贴到之前的应用中。
3. **删除功能**：选择一个剪贴板项目，按 Delete 键，确认该项被删除。
4. **设置生效**：在设置中关闭/开启剪贴板历史，确认功能正确启停；修改容量限制，确认生效。
5. 运行测试套件，确认无回归。

## 阶段 4：提取 SnippetModule

### 工作内容

1. 创建 `LingXi/Panel/Modules/SnippetModule.swift`：
   - 封装 `SnippetStore`、`SnippetExpander`、`SnippetEditorPanel`
   - 在 `register()` 中注册 `SnippetSearchProvider`
   - 在 `bindEvents()` 中处理 `onSnippetPaste`
   - 提供 `showEditor()` 方法供外部调用
2. 修改 `PanelManager`：
   - 移除 `snippetStore`、`snippetExpander`、`snippetEditorPanel` 属性
   - 移除 snippet 相关的 `router.register()` 调用
   - 移除 `viewModel.onSnippetPaste` 赋值
   - 移除 `applySettings()` 中的 snippet 相关逻辑
   - 将 `createPanel()` 中的 `onCommandN` 处理改为通过 `SnippetModule` 调用

### 验证方法

1. **搜索**：输入 snippet 前缀，确认能搜索到片段。
2. **粘贴**：选择一个 snippet，确认内容被正确展开和粘贴。
3. **编辑器**：在 snippet 搜索结果中按 `Cmd+N`，确认编辑器弹出；保存后 snippet 列表刷新。
4. **自动展开**：开启自动展开，输入缩写，确认自动替换。
5. 运行测试套件，确认无回归。

## 阶段 5：提取 CommandModule

### 工作内容

1. 创建 `LingXi/Panel/Modules/CommandModule.swift`：
   - 封装 `CommandSearchProvider` 和 `PromotedCommandSearchProvider`
   - 在 `register()` 中注册两个 Provider
   - 在 `bindEvents()` 中处理 `onCommandExecute`
   - 实现 `PluginAwareModule`，在 `afterPluginsLoaded()` 中注册内置命令和插件命令
2. 修改 `PanelManager`：
   - 移除 `commandProvider` 属性
   - 移除 command 相关的 `router.register()` 调用
   - 移除 `viewModel.onCommandExecute` 赋值
   - 移除 `applySettings()` 中的 command 相关逻辑
   - 移除 `registerBuiltinCommands` 和 `registerPluginCommands` 静态方法
   - 将 PluginManager 的 commandProvider 设置改为在 CommandModule 中完成

### 验证方法

1. **命令搜索**：输入 `>` 前缀，确认内置命令（settings、help、screenshot 等）出现。
2. **命令执行**：选择一个命令，确认正确执行。
3. **插件命令**：输入 `plugin:reload`、`plugin:list`，确认正常工作。
4. **设置开关**：关闭/开启命令搜索，确认生效。
5. 运行测试套件，确认无回归。

## 阶段 6：提取剩余 Provider 模块

### 工作内容

分别创建以下模块，每个模块的职责单一：

1. **ApplicationModule**（默认 Provider）
2. **FileSearchModule**（含 FileSearchProvider 和文件夹/文件两个实例）
3. **BookmarkModule**
4. **SystemSettingsModule**（含 SystemSettingsProvider 和 SystemSettingsMixedProvider）

每个模块：
- 在 `register()` 中注册对应的 Provider
- 在 `applySettings()` 中更新前缀和启用状态
- 不需要绑定事件（如无特殊处理）

修改 `PanelManager`：
- 移除所有 Provider 的硬编码注册
- 移除 `applySettings()` 中的所有 Provider 相关逻辑
- 改为接收 `[SearchProviderModule]` 数组

### 验证方法

每个模块完成后，人工验证对应的搜索前缀功能：

1. **应用搜索**：不输入前缀，确认应用搜索结果正常。
2. **文件搜索**：输入文件前缀，确认文件搜索结果正常。
3. **文件夹搜索**：输入文件夹前缀，确认文件夹搜索结果正常。
4. **书签搜索**：输入书签前缀，确认书签搜索结果正常。
5. **系统设置**：输入系统设置前缀，确认系统设置搜索结果正常；无前缀时确认混合结果包含系统设置。
6. 运行测试套件，确认无回归。

## 阶段 7：清理 PanelManager

### 工作内容

1. 移除 PanelManager 中所有已迁移的 Provider 相关代码。
2. 确保 PanelManager 只保留：
   - `panel`、`viewModel`、`router`、`inputSourceManager`、`previousApp`、`sizeObserver`
   - 面板显示/隐藏/定位逻辑
   - 键盘事件处理（onArrowUp、onArrowDown、onReturn 等）
   - 设置变更的转发（`applySettings` 遍历 modules）
3. 检查是否有未使用的 import，清理之。

### 验证方法

1. **代码审查**：确认 PanelManager 中不再直接引用任何具体的 Provider 或 Store。
2. **编译通过**。
3. **功能回归测试**：依次测试所有搜索功能（应用、文件、文件夹、书签、剪贴板、snippet、命令、系统设置），确认全部正常。
4. 运行完整测试套件。

## 阶段 8：创建 Assembly/Composition Root

### 工作内容

1. 创建 `LingXi/AppAssembly.swift`（或 `AppDelegate` 中的私有方法）：
   ```swift
   @MainActor
   final class AppAssembly {
       static func assemble(settings: AppSettings) async -> (PanelManager, PluginManager) {
           // 1. 创建 PluginManager
           // 2. 创建 DatabaseManager
           // 3. 按顺序创建各 Module
           // 4. 组装 PanelManager
           // 5. 加载插件并通知 PluginAwareModule
       }
   }
   ```
2. 在 `AppDelegate` 中调用 `AppAssembly.assemble()` 替代直接创建 `PanelManager`。
3. 确保 `PluginManager` 在应用生命周期中保持存活（如作为 AppDelegate 的属性）。

### 验证方法

1. **启动测试**：应用正常启动，无崩溃。
2. **功能全量测试**：逐一验证所有搜索和命令功能。
3. **插件系统**：确认插件加载、事件分发、命令注册全部正常。
4. **设置变更**：在运行时修改设置，确认各模块正确响应。
5. 运行完整测试套件。

## 阶段 9：文档和清理

### 工作内容

1. 在 `docs/architecture.md`（或新建文件）中记录新的模块架构。
2. 为 `SearchProviderModule` 和 `PanelContext` 协议添加文档注释。
3. 检查是否有遗漏的硬编码字符串或 ID，考虑使用常量。
4. 运行 linter（如 SwiftLint）和格式化工具。

### 验证方法

1. **文档审查**：确认文档准确描述了架构和如何新增 Provider。
2. **编译无警告**（尽可能）。
3. 运行完整测试套件。

## 回滚策略

每个阶段完成后立即 commit。如果某阶段验证失败，可以：
- 在该阶段内修复（推荐）
- 回滚到上一阶段的 commit，重新实施

## 注意事项

1. **并发安全**：所有模块在 `@MainActor` 上运行，Store 的初始化可能需要在 `init` 中使用 `await`。
2. **循环依赖**：PanelManager 实现 `PanelContext` 协议，通过 `weak self` 避免循环引用。
3. **PluginManager 生命周期**：PluginManager 必须在 PanelManager 之前创建，在应用退出时释放。
4. **测试隔离**：新增 Module 的测试时，使用 mock 的 `PanelContext` 和 `PluginService`。
