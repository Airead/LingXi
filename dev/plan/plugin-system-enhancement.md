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

## 阶段 7：插件市场 CLI（安装/卸载/列表）

### 工作内容

1. **定义 registry.toml 格式**
   ```toml
   name = "LingXi Official"
   url = "https://github.com/airead/lingxi-plugins"
   
   [[plugins]]
   id = "io.github.airead.lingxi.emoji-search"
   name = "Emoji Search"
   version = "1.0.0"
   description = "Search emojis by keyword"
   author = "LingXi Team"
   source = "https://raw.githubusercontent.com/.../plugin.toml"
   min_lingxi_version = "0.1.0"
   ```

2. **实现安装流程**
   - `plugin:install <id>`：从注册表查找插件，下载并安装
   - `plugin:install <url>`：从 URL 直接安装（zip 或目录）
   - 安装后生成 `install.toml`

3. **实现 uninstall**
   - `plugin:uninstall <id>`：删除插件目录

4. **实现 list**
   - `plugin:list`：显示已安装插件（已有，需增强显示版本和来源）

5. **注册表管理命令**
   - `plugin:registry add <url>`
   - `plugin:registry remove <name>`
   - `plugin:registry list`

### 验证方法

1. **创建本地测试注册表**
   - 在 `~/.config/LingXi/registries/test.toml` 放置测试 registry.toml
   - 指向本地或 GitHub 上的测试插件

2. **人工验证**：
   - `plugin:registry add <本地 registry.toml 路径>`
   - `plugin:registry list`，确认注册表已添加
   - `plugin:install <测试插件 id>`，确认插件下载到 `plugins/` 目录
   - 检查插件目录包含 `install.toml`
   - `plugin:list`，确认显示新版本信息
   - `plugin:uninstall <id>`，确认目录被删除
   - `plugin:install <zip 文件 URL>`，确认 URL 安装方式工作

---

## 阶段 8：插件更新与版本管理

### 工作内容

1. **版本比较**
   - 实现语义化版本比较（`1.0.0` < `1.0.1` < `1.1.0` < `2.0.0`）

2. **实现更新检查**
   - `PluginUpdater.checkAll()`：对比已安装版本与注册表最新版本
   - `plugin:update <id>`：更新单个插件
   - `plugin:update`：更新所有有更新的插件

3. **更新流程**
   - 下载新版本 → 备份旧版本 → 替换 → 重载插件
   - 失败时回滚到备份

4. **版本兼容性检查**
   - 安装/更新前检查 `min_lingxi_version`
   - 如果不兼容，拒绝安装并提示

5. **install.toml 增强**
   ```toml
   [install]
   source_url = "..."
   installed_version = "1.0.0"
   installed_at = "2026-04-21T10:00:00Z"
   registry = "LingXi Official"
   pinned = false  -- 是否固定版本（暂不实现 pin 功能，预留字段）
   ```

### 验证方法

1. **准备测试场景**
   - 本地 registry.toml 中有一个插件版本为 `1.0.0`
   - 安装该插件
   - 修改 registry.toml 中该插件版本为 `1.0.1`（模拟更新）

2. **人工验证**：
   - `plugin:list`，确认当前版本为 `1.0.0`
   - `plugin:update`，确认检测到更新并自动升级
   - 检查 `install.toml` 中版本变为 `1.0.1`
   - 测试 `min_lingxi_version = "99.0.0"` 的插件，确认安装被拒绝
   - 测试更新失败场景（如断网），确认旧版本仍然可用

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
