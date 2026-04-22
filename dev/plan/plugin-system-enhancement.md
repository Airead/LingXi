# LingXi 插件系统增强计划

## 目标

在现有 Lua 插件系统基础上，参考 WenZi 插件系统设计，引入元数据声明、分级权限、丰富 API 和插件市场，构建安全且可扩展的插件生态。

## 设计原则

1. **保留 Lua**：继续使用 Lua 5.4 作为插件语言，轻量且易沙箱化
2. **聚焦搜索**：不引入 WebView/Menubar/Leader Key 等 UI 扩展，保持产品定位
3. **分级权限**：插件声明权限，宿主动态控制 API 暴露范围
4. **向后兼容**：现有纯 Lua 全局表的插件继续工作
5. **每阶段可验证**：每个阶段完成后可通过人工操作验证功能

---

## 阶段 1：plugin.toml 元数据与分级权限

### 工作内容

1. **创建 TOML 解析依赖**
   - 在 `Package.swift` 引入 `swift-toml` 或自研轻量 TOML 解析器（推荐自研，零外部依赖）
   - 或评估是否可用系统 `Foundation` 的 `PropertyListSerialization` 折中（但保持 TOML 格式）

2. **定义数据结构**
   - 创建 `LingXi/Plugin/PluginManifest.swift`：
     ```swift
      struct PluginManifest: Sendable {
          let id: String
          let name: String
          let version: String
          let author: String
          let description: String
          let minLingXiVersion: String
          let search: SearchConfig?
          let permissions: PermissionConfig
          let commands: [ManifestCommand]
      }

      struct SearchConfig: Sendable {
          let prefix: String          // 搜索前缀，默认使用 plugin.id
          let debounce: Int           // 去抖毫秒数，默认 100
          let timeout: Int            // 超时毫秒数，默认 5000
      }

      struct PermissionConfig: Sendable {
          let network: Bool
          let clipboard: Bool
          let filesystem: [String]      // 路径白名单
          let shell: [String]           // 命令白名单，空数组=禁用
          let notify: Bool
      }
     ```

3. **创建 plugin.toml 解析器**
   - `LingXi/Plugin/ManifestParser.swift`
   - 解析 `plugin.toml`，回退到 `plugin.lua` 全局表（向后兼容）

4. **实现动态沙箱**
   - 修改 `LuaSandbox.apply(to:permissions:)`
   - 根据 `PermissionConfig` 动态移除未授权的 `lingxi` 子模块
   - 网络禁用 → 移除 `lingxi.http`
   - 剪贴板禁用 → 移除 `lingxi.clipboard`
   - Shell 禁用 → 移除 `lingxi.shell`

5. **修改加载流程**
   - `PluginManager.loadAll()` 先读 `plugin.toml`，再执行 `plugin.lua`
   - 权限不足时记录 warning 但不阻止加载（只是 API 不可用）

### 验证方法

1. **创建测试插件** `~/.config/LingXi/plugins/test-permissions/plugin.toml`：
   ```toml
   [plugin]
   id = "test.permissions"
   name = "Test Permissions"
   version = "1.0.0"
   
   [permissions]
   network = false
   clipboard = true
   shell = []
   ```

2. **在 plugin.lua 中测试**：
   ```lua
   function search(query)
       -- 尝试调用 lingxi.http.get，应报错
       local ok, err = pcall(function()
           return lingxi.http.get("https://example.com")
       end)
       
       -- 尝试调用 lingxi.clipboard.read，应成功
       local text = lingxi.clipboard.read()
       
       return {{
           title = "HTTP disabled: " .. tostring(not ok),
           subtitle = "Clipboard: " .. tostring(text ~= nil),
           action = "copy"
       }}
   end
   ```

3. **人工验证**：
   - 输入测试插件前缀，确认 HTTP 调用失败、剪贴板调用成功
   - 修改 `plugin.toml` 将 `network = true`，重载插件，确认 HTTP 可用
   - 删除 `plugin.toml`，仅保留 Lua 全局表，确认向后兼容

---

## 阶段 2：lingxi.store API（插件隔离存储）

### 工作内容

1. **创建 StoreManager**
   - `LingXi/Plugin/StoreManager.swift`
   - Actor 隔离，每个插件独立 JSON 文件
   - 存储路径：`~/.config/LingXi/plugin-data/<plugin-id>.json`

2. **实现 Lua API**
   ```lua
   lingxi.store.get(key) -> any | nil
   lingxi.store.set(key, value) -> boolean
   lingxi.store.delete(key) -> boolean
   ```
   - 支持 string/number/boolean/table 类型
   - 自动序列化为 JSON

3. **注册到 LuaAPI**
   - 在 `LuaAPI.registerAll` 中添加 `registerStore(state:pluginId:)`
   - Store 实例绑定到具体插件 ID，隔离数据

### 验证方法

1. **创建测试插件**：
   ```lua
   -- plugin.lua
   function search(query)
       local count = lingxi.store.get("search_count") or 0
       count = count + 1
       lingxi.store.set("search_count", count)
       
       return {{
           title = "Search count: " .. count,
           subtitle = "Query: " .. query,
           action = "copy"
       }}
   end
   ```

2. **人工验证**：
   - 多次触发搜索，确认计数递增
   - 重启应用，再次搜索，确认计数从上次继续（数据持久化）
   - 检查 `~/.config/LingXi/plugin-data/<plugin-id>.json` 内容正确
   - 创建第二个插件，确认两个插件的 store 数据隔离

---

## 阶段 3：lingxi.file API（受控文件访问）

### 工作内容

1. **路径校验工具**
   - `LingXi/Plugin/PathValidator.swift`
   - 支持 `~` 展开、相对路径解析
   - 校验路径是否在 `filesystem` 白名单内

2. **实现 Lua API**
   ```lua
   lingxi.file.read(path) -> string | nil
   lingxi.file.write(path, content) -> boolean
   lingxi.file.list(dir) -> {name: string, isDir: boolean}[] | nil
   lingxi.file.exists(path) -> boolean
   ```

3. **权限检查**
   - 每个 API 调用前校验路径
   - 越权访问返回 `nil` 或 `false`，并记录 warning
   - 未声明 `filesystem` 权限时，file 模块完全不可用

### 验证方法

1. **创建测试插件**，`plugin.toml`：
   ```toml
   [plugin]
   id = "test.file"
   name = "Test File"
   version = "1.0.0"

   [search]
   prefix = "tf"

   [permissions]
   filesystem = ["~/.config/LingXi/plugins/test-file/"]
   ```

2. **plugin.lua**：
   ```lua
   function search(query)
       local ok1 = lingxi.file.write("~/.config/LingXi/plugins/test-file/data.txt", "hello")
       local ok2 = lingxi.file.write("/tmp/hacked.txt", "bad")  -- 应失败
       local content = lingxi.file.read("~/.config/LingXi/plugins/test-file/data.txt")
       
       return {{
           title = "Write allowed: " .. tostring(ok1),
           subtitle = "Write denied: " .. tostring(not ok2) .. " | Content: " .. (content or "nil"),
           action = "copy"
       }}
   end
   ```

3. **人工验证**：
   - 确认白名单路径内读写成功
   - 确认白名单路径外写失败
   - 确认 `lingxi.file.list` 能列出插件目录内容
   - 移除 `filesystem` 权限，确认 file 模块不可用

---

## 阶段 4：lingxi.shell API（可控命令执行）

### 工作内容

1. **命令白名单校验**
   - 解析命令字符串，提取第一个 token（命令名）
   - 校验命令名是否在 `shell` 白名单内
   - 支持绝对路径命令（如 `/usr/bin/open`）和 PATH 搜索

2. **实现 Lua API**
   ```lua
   lingxi.shell.exec(cmd) -> {exitCode: number, stdout: string, stderr: string}
   ```
   - 使用 `Process` 执行命令
   - 设置超时（如 30 秒）
   - 超时或执行失败时返回非零 exitCode

3. **安全限制**
   - 禁止管道、重定向、分号等 shell 元字符（或限制为简单命令）
   - 或直接使用 `Process(arguments:)` 避免 shell 解析
   - 记录所有 shell 执行到日志

### 验证方法

1. **创建测试插件**，`plugin.toml`：
   ```toml
   [plugin]
   id = "test.shell"
   name = "Test Shell"
   version = "1.0.0"

   [search]
   prefix = "sh"

   [permissions]
   shell = ["echo", "date", "ls"]
   ```

2. **plugin.lua**：
   ```lua
   function search(query)
       local result1 = lingxi.shell.exec("echo hello")
       local result2 = lingxi.shell.exec("rm -rf /")  -- 应失败（命令不在白名单）
       
       return {{
           title = "Echo: " .. result1.stdout,
           subtitle = "Bad cmd exit: " .. result2.exitCode,
           action = "copy"
       }}
   end
   ```

3. **人工验证**：
   - 白名单命令执行成功，stdout 正确
   - 非白名单命令返回非零 exitCode 或错误
   - 移除 `shell` 权限或设为空数组，确认 shell 模块不可用

---

## 阶段 5：事件系统扩展

### 工作内容

1. **扩展事件枚举**
   ```swift
   enum PluginEvent: String {
       case clipboardChange = "clipboard_change"
       case searchActivate = "search_activate"
       case searchDeactivate = "search_deactivate"
       case appLaunch = "app_launch"
       case screenshotCaptured = "screenshot_captured"
       case pluginReload = "plugin_reload"
   }
   ```

2. **标准化事件数据**
   - 定义每个事件的数据格式（string key-value）
   - `clipboard_change`: `{type: "text|image"}`
   - `search_activate`: `{query: string}`
   - `screenshot_captured`: `{path: string}`

3. **修改事件分发**
   - `PluginManager.dispatchEvent` 支持新事件
   - 在对应业务代码中触发事件（如剪贴板变更、搜索打开、截图完成）

4. **Lua 侧约定**
   ```lua
   function on_event(event, data)
       -- event: string
       -- data: table (string keys)
   end
   ```
   - 如果插件定义了全局 `on_event` 函数，自动注册为监听器

### 验证方法

1. **创建测试插件**：
   ```lua
   local events = {}
   
   function on_event(event, data)
       table.insert(events, event .. ":" .. (data.query or data.type or ""))
       if #events > 10 then table.remove(events, 1) end
   end
   
   function search(query)
       local text = table.concat(events, " | ")
       return {{
           title = "Recent events",
           subtitle = text,
           action = "copy"
       }}
   end
   ```

2. **人工验证**：
   - 打开搜索面板，确认 `search_activate` 事件被记录
   - 复制一段文字，确认 `clipboard_change` 事件被记录
   - 执行截图，确认 `screenshot_captured` 事件被记录
   - 执行 `plugin:reload`，确认 `plugin_reload` 事件被记录
   - 关闭面板，确认 `search_deactivate` 事件被记录

---

## 阶段 6：lingxi.ui API（系统通知与浮动提示）

### 工作内容

1. **实现 lingxi.notify**
   ```lua
   lingxi.notify(title: string, message?: string) -> boolean
   ```
   - 使用 `UNUserNotificationCenter` 发送系统通知
   - 需要请求通知权限

2. **实现 lingxi.alert**
   ```lua
   lingxi.alert(text: string, duration?: number) -> boolean
   ```
   - 复用现有浮动提示组件（类似 WenZi 的 `wz.alert`）
   - 或创建简单 Toast 窗口
   - `duration` 单位：秒，默认 2 秒

3. **权限控制**
   - `notify = true` 时 lingxi.notify 可用
   - alert 无需特殊权限（纯 UI 展示）

### 验证方法

1. **创建测试插件**：
   ```lua
   function search(query)
       lingxi.notify("LingXi Plugin", "You searched for: " .. query)
       lingxi.alert("Search triggered!", 3)
       
       return {{
           title = "Notification sent",
           subtitle = "Check system notification center",
           action = "copy"
       }}
   end
   ```

2. **人工验证**：
   - 触发搜索，确认系统通知弹出（需在系统设置中允许 LingXi 通知）
   - 确认浮动提示显示 3 秒后消失
   - 将 `notify` 设为 false，确认 notify 调用失败但 alert 仍可用

---

## 阶段 7：插件市场 CLI（安装/卸载/列表/更新）

### 设计概要

> **重要约定**：所有 LingXi 缓存路径禁止硬编码。后续所有缓存相关内容统一放在 `~/.cache/LingXi/` 目录下，通过共享配置或环境变量获取，确保一致性和可维护性。

1. **官方 Registry**：从 GitHub 远程获取（`https://raw.githubusercontent.com/Airead/LingXi/main/plugins/registry.toml`），本地缓存 24h
2. **Plugin.toml 扩展**：`files = ["plugin.lua", "data.json"]` 列出所有需下载的文件
3. **无 ZIP 支持**：逐个文件从 GitHub raw URL 下载
4. **默认禁用**：安装后自动加入 `disabled_plugins`，需手动 `plugin:enable`
5. **手动插件检测**：无 `install.toml` 的目录标记为 `MANUALLY_PLACED`，正常加载
6. **版本兼容性**：安装/更新前检查 `min_lingxi_version`，不兼容则拒绝
7. **CLI 先行**：配置界面将在后续阶段实现

### 新增文件

- `LingXi/Plugin/PluginRegistry.swift` — Registry 数据结构与解析
- `LingXi/Plugin/RegistryManager.swift` — 远程获取、缓存、TTL 管理
- `LingXi/Plugin/InstallManifest.swift` — `install.toml` 读写
- `LingXi/Plugin/PluginMarket.swift` — 安装/卸载/更新核心逻辑
- `LingXi/Plugin/Semver.swift` — 语义化版本比较

### registry.toml 格式

```toml
name = "LingXi Official"
url = "https://github.com/Airead/LingXi"

[[plugins]]
id = "io.github.airead.lingxi.emoji-search"
name = "Emoji Search"
version = "1.0.0"
description = "Search emojis by keyword"
author = "LingXi Team"
source = "https://raw.githubusercontent.com/Airead/LingXi/main/plugins/emoji-search/plugin.toml"
min_lingxi_version = "0.1.0"
```

### plugin.toml 扩展格式（files 数组）

```toml
[plugin]
id = "io.github.airead.lingxi.emoji-search"
name = "Emoji Search"
description = "Search emojis by keyword"
version = "1.0.0"
author = "LingXi Team"
url = "https://github.com/Airead/LingXi"
min_lingxi_version = "0.1.0"

files = [
    "plugin.lua",
    "emoji-data.json",
]

[search]
prefix = "emoji"

[permissions]
network = true
clipboard = false
shell = []
```

### install.toml 格式

```toml
[install]
source_url = "https://raw.githubusercontent.com/Airead/LingXi/main/plugins/emoji-search/plugin.toml"
installed_version = "1.0.0"
installed_at = "2026-04-22T10:00:00Z"
pinned_ref = ""            # 预留字段
```

### 插件状态枚举

```swift
enum PluginStatus: String {
    case notInstalled = "not_installed"
    case installed = "installed"
    case updateAvailable = "update_available"
    case manuallyPlaced = "manually_placed"
    case disabled = "disabled"
}
```

### 子阶段 7.1：Registry Manager

**工作内容**：
1. `PluginRegistryEntry`、`RegistryPlugin` 数据结构
2. `RegistryParser`：使用现有 `TOMLParser` 解析 registry.toml
3. `RegistryManager`：
   - `fetchRegistry()`：从 `BUILTIN_REGISTRY_URL` 下载
   - `cachedRegistry()`：读取本地缓存（`~/.cache/LingXi/registry.toml`）
   - `refreshRegistry()`：下载并写入缓存，24h TTL
   - 网络失败时回退到缓存
4. `Semver`：语义化版本比较（`major.minor.patch`）

**验证方法**：
1. 创建本地测试 registry.toml
2. `RegistryParser` 正确解析
3. `Semver.compare("1.0.0", "1.0.1")` 返回 `.orderedAscending`
4. `RegistryManager` 获取并缓存到临时目录
5. 断网时使用缓存文件，不报错

### 子阶段 7.2：Plugin Market Core

**工作内容**：
1. `InstallInfo` 结构体 + `install.toml` 读写
2. `PluginMarket` actor：
   - `install(id:)`：从 registry 查找并下载
   - `install(url:)`：从 plugin.toml URL 直接安装
   - `uninstall(id:)`：删除插件目录
   - `listInstalled()`：扫描 plugins/ 目录
   - `listAvailable()`：从 registry 获取可安装列表
   - `checkUpdates()`：对比版本
3. 安装流程：
   1. 下载 `plugin.toml`
   2. 解析 manifest，检查 `min_lingxi_version`
   3. 创建 `plugins/<id>/` 目录
   4. 下载 `files` 数组中的所有文件（同 base URL）
   5. 写入 `install.toml`
   6. 加入 `disabled_plugins`（默认禁用）
4. 路径安全：验证 plugin ID，防止目录遍历

**验证方法**：
1. 在临时 HTTP 服务放置测试插件（plugin.toml + plugin.lua）
2. `plugin:install <id>` 下载文件到 `plugins/<id>/`
3. 检查 `install.toml` 存在且版本正确
4. 检查 `disabled_plugins` 包含新插件 ID
5. `plugin:uninstall <id>` 删除目录
6. `plugin:install <url>` 支持直接 URL
7. `min_lingxi_version = "99.0.0"` 时安装被拒绝

### 子阶段 7.3：CLI 命令集成

**工作内容**：
1. `PluginManager` 增强：
   - `uninstall(pluginId:)`
   - `installedPlugins` 属性
   - 读取 `disabled_plugins`，跳过加载
   - `enable(pluginId:)` / `disable(pluginId:)` 修改配置并重载
2. `CommandModule` 新增命令：
   - `plugin:install <id>` — 从 registry 安装
   - `plugin:install <url>` — 从 URL 安装
   - `plugin:uninstall <id>`
   - `plugin:update <id>` — 更新单个插件
   - `plugin:update` — 更新所有有更新的插件
   - `plugin:enable <id>` — 启用插件
   - `plugin:disable <id>` — 禁用插件
   - `plugin:registry refresh` — 强制刷新 registry 缓存
   - 增强 `plugin:list` — 显示版本、状态（disabled/manual/update-available）

**验证方法**：
1. `plugin:install` → `plugin:list` 显示 `(disabled)`
2. `plugin:enable` → reload → 插件激活
3. `plugin:disable` → reload → 插件不加载但文件保留
4. `plugin:uninstall` → 目录删除
5. `plugin:update` 检测并安装新版本
6. `plugin:registry refresh` 更新缓存文件时间戳

### 子阶段 7.4：手动插件检测

**工作内容**：
1. `PluginManager.loadAll()` 扫描时：
   - 有 `plugin.toml` 但无 `install.toml` → `MANUALLY_PLACED`
   - 正常加载，日志警告
2. `plugin:list` 显示 `(manual)`
3. `plugin:uninstall` 支持手动插件

**验证方法**：
1. 手动创建 `plugins/test.manual/`（含 plugin.toml + plugin.lua，无 install.toml）
2. 重启 LingXi，`plugin:list` 显示 `(manual)`
3. 插件功能正常
4. `plugin:uninstall test.manual` 删除目录

### 子阶段 7.5：更新检测

**工作内容**：
1. `PluginMarket.checkUpdates()`：
   - 扫描所有已安装插件
   - 对比 registry version vs install.toml version
   - registry 版本更高 → `UPDATE_AVAILABLE`
2. `plugin:update <id>` 流程：
   1. 检查更新可用
   2. 备份旧目录（`plugins/<id>.backup/`）
   3. 重新下载所有文件
   4. 失败时恢复备份
   5. 更新 `install.toml`
   6. Reload 插件
3. 启动时后台检查更新，日志提示

**验证方法**：
1. 安装插件 v1.0.0
2. 手动修改缓存 registry.toml 为 v1.0.1
3. `plugin:list` 显示 `(update available)`
4. `plugin:update <id>` 下载新版本
5. `install.toml` 版本变为 1.0.1
6. 插件功能正常
7. 模拟更新失败（如断网），旧版本仍然可用

---

## 阶段 8：插件市场配置界面（后续阶段）

### 工作内容

1. **Settings 窗口新增 Plugins Tab**
   - 插件列表：名称、版本、状态、描述
   - 操作按钮：安装/卸载/启用/禁用/更新
   - 详情区域：权限、作者、描述
2. **状态显示**
   - 颜色或图标区分状态（未安装/已安装/有更新/已禁用/手动放置）
3. **Registry 刷新按钮**
   - 手动触发 registry 刷新

### 验证方法

1. 打开 Settings → Plugins Tab
2. 确认列表与 `plugin:list` 一致
3. 点击安装/卸载/更新按钮，功能正常
4. 状态变化实时反映在列表中

---

---

## 回滚策略

每个阶段完成后立即 commit。验证失败时：
- 优先在当前阶段内修复
- 无法修复则回滚到上一阶段 commit，重新实施

---

## 注意事项

1. **并发安全**：所有新增 Manager 使用 Swift actor 隔离，与 `PluginManager` 协同时注意 `@MainActor` 边界
2. **向后兼容**：每个阶段确保旧格式插件（纯 Lua 全局表）继续工作
3. **路径安全**：所有涉及文件系统的操作必须校验路径，防止目录遍历攻击
4. **测试隔离**：新增测试时使用临时目录替代 `~/.config/LingXi/`，避免污染用户环境
5. **零依赖**：优先使用系统框架，避免引入第三方 Swift 包（TOML 解析可考虑轻量自研）
