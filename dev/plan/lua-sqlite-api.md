# Lua 插件 SQLite API 实现计划

## 背景

当前 LingXi 的 Lua 插件已有 `lingxi.store`（KV）、`lingxi.file`（受 `filesystem` 白名单限制）、`lingxi.cache` 等能力，但缺少结构化数据查询能力。部分插件场景（例如读取 Claude Code 会话 JSONL 的索引、读取其它 app 暴露出来的 sqlite 历史库）需要真正的 SQL 查询。

宿主已用裸 `SQLite3` C API（见 `LingXi/Storage/DatabaseManager.swift`）实现了 `actor DatabaseManager`，为暴露给 Lua 提供了现成基础。

## 目标

1. 新增 `lingxi.db` API，支持两种场景：
   - **自有库**：插件在 `~/.cache/LingXi/<plugin-id>/db/` 下读写自己的 sqlite 文件。
   - **外部库**：插件只读访问用户在 manifest 里声明的第三方 sqlite 文件。
2. 权限模型与 `filesystem` 解耦，新增 `db` 开关 + `db_external_paths` 白名单。
3. API 设计走"高层优先"：`exec / query / queryOne / transaction`，暂不暴露 `prepare/step`。
4. 沿用 `PermissionConfig` 的 enabled/disabled 双路注册模式，无权限时返回 nil/false + 警告日志。
5. 并发模型与 `DatabaseManager` 一致：每个 DB 连接一个 serial actor，Lua VM 线程走 `syncXxx` 包装。

## 非目标

- **不暴露 `prepare/step/finalize`**：一期不做流式游标，全部 query 物化到 Lua table。后续如有大结果集场景再按需扩展 `db:iterate()`。
- **不实现 ORM/schema 迁移辅助**：插件自行管理 schema。
- **不做跨插件共享库**：每个插件只能开自己命名空间下的自有库。
- **不解决 macOS TCC（Full Disk Access）问题**：这是 OS 层权限，框架只负责把错误分类清晰。

## 权限模型

### manifest 扩展

```toml
[permissions]
db = true                               # 是否启用 lingxi.db.* API
db_external_paths = [                   # 外部库白名单（只读）
  "~/Library/Application Support/Foo/history.db",
  "~/Library/Messages/chat.db"
]
```

- `db: false / 缺省` → 所有 `lingxi.db.*` 都是 disabled stub。
- `db_external_paths`：绝对路径或 `~` 前缀；走 `PathValidator` 规范化 + symlink 解析，前缀匹配。
- **自有库不走 `db_external_paths`**：路径固定在 `~/.cache/LingXi/<plugin-id>/db/<name>.sqlite`，只需要 `db = true`。

### 为什么不复用 `filesystem`

1. 语义分离：`filesystem` 是读写通用的，`db_external_paths` 从第一天就是只读。
2. 装插件时用户看权限声明更直观："这个插件要读 Messages 聊天库"不被淹没在文件路径里。
3. 未来敏感前缀（`~/Library/**`）若要强制交互式授权（`NSOpenPanel`），只动 db 分支。
4. 避免无意扩权：filesystem 给了 `~/Downloads/` 不代表插件能把 Downloads 里任意 sqlite 当 DB 打开分析。

## Lua API

### 自有库

```lua
local db = lingxi.db.open("sessions")        -- 返回 db 句柄
db:exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)")
db:exec("INSERT INTO t(name) VALUES(?)", {"Alice"})   -- 返回 changes
local rows = db:query("SELECT * FROM t WHERE id > ?", {0})
local one  = db:queryOne("SELECT * FROM t WHERE id = ?", {1})
db:transaction(function()
  db:exec("...")
  db:exec("...")
end)
db:close()
```

- `open(name)` 只接受文件名（不含路径分隔符），路径在宿主侧拼：`~/.cache/LingXi/<plugin-id>/db/<name>.sqlite`。
- 拒绝 `.`, `..`, `/`, `\0` 等字符。
- 首次 open 时默认执行 `PRAGMA journal_mode=WAL; foreign_keys=ON; busy_timeout=5000;`。

### 外部库

```lua
local db = lingxi.db.openExternal("~/Library/Application Support/Foo/history.db")
local rows = db:query("SELECT url, visit_time FROM visits LIMIT 100")
db:close()
-- db:exec / db:transaction 在外部库句柄上不存在（方法表不挂）
```

- 使用 `PathValidator(allowedPaths: db_external_paths)` 校验。
- 打开用 URI：`file:<canonical>?mode=ro&immutable=1`；flags `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`。
- 句柄在 Lua 侧是**不同类型**（不同 metatable），从根源上避免调用到写接口。

### 快照辅助（外部库可选）

```lua
local snapshot_path = lingxi.db.snapshot("~/Library/.../History.db")
local db = lingxi.db.openExternal(snapshot_path)
```

- 把源库复制到 `~/.cache/LingXi/<plugin-id>/snapshots/<hash>.sqlite`，返回本地路径。
- 解决"源库被别的进程并发写导致 `SQLITE_BUSY`"的问题，代价是数据有延迟。
- 快照路径本身受 `db_external_paths` 豁免（是插件自己 cache 目录下的副本）。

## 实现结构（Swift 侧）

新增文件：

```
LingXi/Plugin/LuaDBAPI.swift        -- Lua C 函数、注册逻辑
LingXi/Plugin/PluginDBManager.swift -- actor，管理所有插件的连接
```

### `PluginDBManager`

```swift
actor PluginDBManager {
    static let shared = PluginDBManager()

    // pluginId -> (handleId -> connection)
    private var connections: [String: [Int: Connection]] = [:]
    private var nextHandleId = 0

    func openOwned(pluginId: String, name: String) -> Int?      // returns handleId
    func openExternal(pluginId: String, canonicalPath: String) -> Int?
    func close(pluginId: String, handleId: Int)
    func closeAll(pluginId: String)                              // 插件 unload 时调

    // 同步包装（给 Lua C 函数用）
    func syncExec(pluginId: String, handleId: Int, sql: String, params: [DatabaseValue]) -> Int
    func syncQuery(pluginId: String, handleId: Int, sql: String, params: [DatabaseValue]) -> [[String: Any]]
    // ...
}

private final class Connection {
    let db: OpaquePointer
    let isReadOnly: Bool
    // ...
}
```

- 每个 `Connection` 内部自己串行化（`DispatchQueue` 或 actor），sqlite 句柄不跨线程用。
- Lua 侧拿到的 "db 句柄" 是一个**整数 handleId**，存在 Lua userdata 里；真正的 `OpaquePointer` 只存在 Swift 侧。
- Lua userdata 的 `__gc` 回调 → `PluginDBManager.close(pluginId, handleId)`，兜底资源释放。

### `LuaDBAPI`

参考 `LuaAPI.swift` 里 `registerStore` / `registerDisabledStore` 的风格：

- `registerDB(state:)` 构建 `lingxi.db` 表 + 两个 metatable（自有 vs 外部）。
- 权限检查在 `registerAll` 里：
  - `db = false` → `registerDisabledDB`（所有方法返回 nil/false + 警告日志）。
  - `db = true` → `registerDB`，其中 `openExternal` 内部再看 `db_external_paths` 是否为空。

### 与现有注册集成

在 `LuaAPI.registerAll` 中加：

```swift
if permissions.db {
    LuaDBAPI.register(state: state)
} else {
    LuaDBAPI.registerDisabled(state: state)
}
```

### 插件生命周期

- `PluginManager` 卸载插件时调 `PluginDBManager.shared.closeAll(pluginId:)`。
- 重载插件（热重载场景，如果有）走同样的 closeAll → register 流程。

## 类型映射

| SQLite     | Lua                          | Swift (`DatabaseValue`) |
|------------|------------------------------|-------------------------|
| NULL       | `nil`                        | `.null`                 |
| INTEGER    | `number` (Lua 5.3+ integer)  | `.integer(Int)`         |
| REAL       | `number`                     | `.real(Double)`         |
| TEXT       | `string`                     | `.text(String)`         |
| BLOB       | `lingxi.db.blob(string)` wrapper table 或返回带 `__blob = true` marker 的 string wrapper | `.blob(Data)` |

- 参数绑定只接受 `?` / `:name` 占位符，不提供字符串拼接辅助函数。
- 查询结果：每行 `[String: Any]` → Lua table（列名为 key）。
- BLOB 一期简化：只支持传入、不暴露便捷绑定语法；插件用 `lingxi.db.blob(binary_string)` 显式包一层。

## 错误处理

所有 API 在出错时：

1. 返回 `nil / false`（和现有 store/file API 一致）。
2. 第二个返回值给一个错误字符串，方便插件 `local rows, err = db:query(...)`。
3. 日志格式：`[LuaDB] <plugin-id>: <operation> failed: <sqlite errmsg>`。

特别处理：

- `SQLITE_CANTOPEN` + 文件存在 → 区分 `EPERM`（TCC）vs 其它，前者日志明确写 "may require Full Disk Access"。
- `SQLITE_BUSY` 超过 busy_timeout → 返回带有 "database busy" 的错误串，插件可重试或走 snapshot。
- Lua 端传入的参数表里有不支持的类型（function/userdata/等）→ 绑定前就拒绝，错误提示列出哪一列。

## 测试计划

新增 `LingXiTests/LuaDBAPITests.swift`，用临时目录隔离：

### 自有库
- `open + exec + query + close` 正常路径
- 参数化 `?` 和 `:name` 绑定
- 事务提交 / 回滚（`db:transaction` 中抛错后数据未变）
- `close` 后再调方法返回 nil+err 而非 crash
- 文件名非法（含 `/` / `..` / 空）被拒
- Lua userdata `__gc` 触发 close

### 外部库
- 白名单命中 / 未命中
- symlink 指向白名单外被 `PathValidator` 拒
- 打开后 `db:exec` 方法不存在（外部句柄 metatable 不挂写方法）
- 不存在的文件返回清晰错误（区分"未授权"vs"文件不存在"）
- `snapshot` 复制到 cache 目录后能正常打开

### 权限
- `db = false` 时所有 API 是 disabled stub
- `db = true` + `db_external_paths = []` 时 `openExternal` 被拒但 `open` 正常
- 插件 unload 触发 `closeAll`，所有连接关闭

**测试隔离**：`PluginDBManager` 接受可注入的 `baseDirectory`，测试传临时目录，不碰 `~/.cache/LingXi/`。

## 分阶段实施

| 阶段 | 范围 | 交付 |
|------|------|------|
| P1 | 自有库：`open / exec / query / queryOne / close` + `db` 权限开关 | 插件能建表、写入、查询自己的 sqlite |
| P2 | 事务：`db:transaction(fn)` | 支持批量写 |
| P3 | 外部库：`openExternal` + `db_external_paths` + PathValidator 接入 | 只读访问第三方库 |
| P4 | 快照：`lingxi.db.snapshot(src)` | 规避并发写冲突 |
| P5 | 错误细化（TCC 识别）、BLOB 支持、文档和示例插件 | API 完整 |

每个阶段单独可合并；P1 完成后其它阶段可按插件需求再推。

## 开放问题

1. **Lua 侧 integer 精度**：Lua 5.3+ 有独立 integer 类型，`lua_pushinteger` 走 64-bit。但项目里 `luaValueToSwift` 当前是否区分？需要先确认，否则 `INT64` 主键在往返转换中精度可能丢失。
2. **BLOB wrapper 的确切形式**：`lingxi.db.blob(str)` 返回 table 还是 light userdata？倾向 table（Lua 侧能 `type()` 区分 + 带 metatable 防误用），但实现上 table 要额外一层 heap 分配，大 BLOB 场景性能差。一期先用 table，P5 评估是否换。
3. **`db_external_paths` 里的路径是允许精确到文件还是必须到目录**？`PathValidator` 现在走前缀匹配，精确到文件的语义是"文件本身被允许"。需要确认 validator 对"白名单条目恰好等于目标路径"是否返回 canonical——读代码是 `canonical == allowedCanonical` 这一条满足，OK。
4. **是否需要限制每个插件的最大连接数 / 总 DB 大小**？一期不做，加监控日志观察实际使用。

## 参考

- 现有 `DatabaseManager`：`LingXi/Storage/DatabaseManager.swift`
- 现有权限门控模式：`LingXi/Plugin/LuaAPI.swift` 的 `registerAll` / `registerStore` / `registerFile`
- 路径校验：`LingXi/Plugin/PathValidator.swift`
- Manifest 结构：`LingXi/Plugin/PluginManifest.swift`
