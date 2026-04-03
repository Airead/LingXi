# 功能需求文档

本文档记录 LingXi 在完成基础搜索功能（阶段一~三）后，需要逐步实现的功能需求。每个功能独立编号，按优先级分组，后续逐个拆解实现。

每个功能附带 WenZi 项目中的参考实现位置（`~/work/wenzi/`），方便实现时对照。

---

## P0：核心体验提升

### F01：模糊匹配增强 ✅

**现状：** 当前仅支持前缀匹配（100分）和子串包含匹配（50分），无法处理缩写、首字母等常见搜索习惯。

**WenZi 参考实现：**
- `src/wenzi/scripting/sources/__init__.py`
  - `fuzzy_match(query, text)` (L120-157)：四级评分主函数，返回 `(matched, score)`
  - `_word_initials(text)` (L160-183)：从单词边界和驼峰提取首字母（如 "Visual Studio Code" → "vsc"）
  - `_chars_in_order(query, text)` (L186-189)：散序字符匹配，迭代器实现
  - `fuzzy_match_fields(query, fields)` (L192-214)：多字段 AND 匹配，查询按空格拆分为多个 term，每个 term 须匹配至少一个字段，返回平均分

**需求：**
- 支持首字母/驼峰缩写匹配：输入 "vsc" 能匹配 "Visual Studio Code"，输入 "gc" 能匹配 "Google Chrome"
- 支持散序字符匹配：输入 "sfri" 能匹配 "Safari"（字符按顺序散布在目标中）
- 评分体系为四级：精确前缀 > 首字母缩写 > 子串包含 > 散序匹配
- 大小写不敏感
- 当多个匹配规则同时满足时，取最高分
- 匹配到的字符需要能被标记出来（为将来 UI 高亮做准备），返回匹配位置信息

**边界情况：**
- 空查询返回空结果
- 查询字符串长于目标字符串时直接不匹配
- 中文、数字、特殊符号作为查询内容时不崩溃

---

### F02：使用频率学习 ✅

**现状：** 搜索结果仅按匹配度排序，无法体现用户偏好。每次搜索同一个词都返回相同排序。

**WenZi 参考实现：**
- `src/wenzi/scripting/sources/usage_tracker.py`（131 行）
  - `UsageTracker` 类：内存中维护 `{query_prefix: {item_id: count}}` 字典
  - `record(query, item_id)` (L83-97)：记录选择，取查询前 3 字符作为 prefix bucket
  - `score(query, item_id)` (L99-113)：返回使用次数
  - `_schedule_flush()` / `_flush()` (L59-81)：延迟 2 秒批量写入 JSON 文件，daemon 线程
  - 线程安全：全程 `threading.Lock` 保护
- `src/wenzi/scripting/ui/chooser_panel.py`
  - `_boost_by_usage(query)` (L964-973)：对 `_current_items` 按使用频率稳定排序
  - 集成点：同步搜索后 (L878)、异步合并后 (L1178)、选中执行时 (L1457) 分别调用

**需求：**
- 记录用户每次选择行为：包含当时的查询词和被选中项的标识
- 搜索结果在匹配度排序基础上，叠加使用频率权重进行二次排序
- 频率权重与查询词相关：输入 "ch" 时选择 "Chrome" 100 次，不应影响输入 "sa" 时 "Chrome" 的排名
- 也记录不带查询词的全局频率，作为空查询时的排序依据
- 数据持久化到本地（重启应用后数据不丢失）
- 提供清除使用记录的能力（在未来的设置界面中使用）

**边界情况：**
- 首次使用无历史数据时，退化为纯匹配度排序
- 数据文件损坏或不可读时，静默忽略并重新开始记录
- 数据量增长不应显著影响搜索性能

---

### F03：异步增量搜索 ✅

**现状：** SearchRouter 等待所有 provider 返回后才展示结果。如果某个 provider 较慢（如文件搜索），用户会看到整体延迟。

**WenZi 参考实现：**
- `src/wenzi/scripting/ui/chooser_panel.py`
  - `_do_search(query)` (L791-927)：搜索入口，先跑同步源立即展示，再分发异步源
  - `_search_generation` (L234)：generation 计数器，每次搜索递增，旧结果通过 generation 比对丢弃
  - `_launch_async_search(source, query, generation)` (L1110-1158)：提交到 asyncio 事件循环，带 `asyncio.wait_for` 超时，完成后通过 `AppHelper.callAfter` 回到主线程
  - `_merge_async_results(source, items, generation)` (L1160-1195)：stale check → 追加到 `_current_items` → 重新 usage boost → 推送到 JS
  - `_schedule_debounced_search(source, query, generation, delay)` (L1207-1243)：per-source NSTimer 去抖
  - `_cancel_all_debounce_timers()` (L1201-1205)：新搜索时取消所有旧的去抖定时器
  - `_get_timeout(source)` / `_get_debounce_delay(source)` (L1098-1108)：per-source 配置，默认超时 5s，默认去抖 0.15s
  - `_pending_async_count` (L235)：追踪进行中的异步源数量，归零时隐藏 loading 指示器

**需求：**
- 多个 provider 并行搜索，结果增量展示：快的 provider 先出结果，慢的 provider 结果到达后自动合并
- 每次搜索有唯一的 generation 标识，旧搜索的迟到结果不会覆盖新搜索的结果
- 支持 per-provider 的去抖延迟：不同源可以有不同的去抖时间（如本地应用搜索 0ms，文件搜索 200ms）
- 支持 per-provider 的超时：超时后丢弃该源的结果，不阻塞整体
- 增量合并时保持已选中项的稳定性：如果用户已经用方向键选中了某项，新结果合并后该项不应跳走
- 结果总数上限（如 50 条），超过时按分数截断

**边界情况：**
- 用户快速连续输入时，中间的搜索应被取消而非堆积
- 某个 provider 抛异常时不影响其他 provider 的结果展示
- 所有 provider 都超时时，显示空结果

---

## P1：数据源扩展

### F04：计算器源

**WenZi 参考实现：**
- `src/wenzi/scripting/sources/calculator_source.py`（270 行）
  - `CalculatorSource` 类 (L115-269)
  - `_looks_like_math(query)` (L71-79)：正则检测是否含数学运算符或函数调用
  - `_is_complete(query)` (L82-83)：检测表达式是否完整（不以运算符结尾）
  - `_try_math_item(query)` (L237-269)：用 `simpleeval` 库安全求值，拒绝 inf/nan，`^` 转为 `**`
  - `_format_number(value)` (L86-105)：整数不带小数点，浮点数带千位分隔符
  - 支持的函数/常量定义 (L29-33)：sin/cos/tan/log/sqrt/abs/ceil/floor/pi/e 等
  - 还支持单位换算 (L39-47, L200-233)：通过 `pint` 库，如 "100 cm to m"

**需求：**
- 无前缀触发：当输入内容为数学表达式时自动识别并计算
- 支持的运算：加减乘除、幂运算、括号、取模
- 支持常见数学函数：sqrt、sin、cos、tan、log、ln、abs、ceil、floor
- 支持常量：pi、e
- 结果显示在第一行，标题为计算结果，副标题为原始表达式
- 回车执行默认动作：将结果复制到剪贴板
- 结果精度：浮点数保留合理位数，整数结果不显示小数点

**边界情况：**
- 输入不完整的表达式（如 "1+"）不显示计算结果也不报错
- 除以零显示为错误提示（如 "Error: Division by zero"）而非崩溃
- 非数学表达式（如 "hello"）不触发计算器
- 表达式包含未知标识符时静默忽略（不展示计算结果）

---

### F05：剪贴板历史

**WenZi 参考实现：**
- `src/wenzi/scripting/clipboard_monitor.py`（900+ 行）
  - `ClipboardMonitor` 类 (L381+)：后台线程轮询 `NSPasteboard.changeCount()`，间隔 0.5s
  - 内容类型优先级 (L573-636)：PNG → Text → TIFF
  - 密码管理器过滤 (L28-40)：检测 `org.nspasteboard.ConcealedType` 等标记，跳过敏感内容
  - 存储：SQLite + WAL 模式 (L149-173)，字段含 text/timestamp/source_app/image_path/OCR
  - 图片存储到磁盘，≥100×100 px 自动 OCR (L771)
  - 过期清理：可配置 max_days（默认 7 天）
- `src/wenzi/scripting/sources/clipboard_source.py`（374 行）
  - `ClipboardSource` 类 (L109-374)：模糊搜索历史条目
  - `paste_text()` (L51-84)：写入剪贴板后模拟 Cmd+V 粘贴
  - `copy_to_clipboard()` (L87-106)：仅复制不粘贴
  - 空查询缓存 (L119)：TTL 10 秒，避免重复查询
  - 时间格式化 (L26-38)："刚刚" / "5分钟前" / "昨天" 等

**需求：**
- 前缀 `cb` 激活，或通过独立快捷键直接呼出
- 监听系统剪贴板变化，自动记录历史条目
- 支持的内容类型：纯文本、富文本、图片、文件路径
- 每条记录保存：内容（或缩略图）、来源应用名称、记录时间
- 列表展示：标题为内容预览（文本截断显示前 N 个字符，图片显示缩略图），副标题为来源应用和时间
- 回车执行默认动作：将选中内容粘贴到当前激活的应用
- Cmd+Enter：仅复制到剪贴板，不粘贴
- 支持删除单条记录（Cmd+Delete）
- 支持搜索过滤：在剪贴板历史中模糊匹配文本内容
- 历史容量上限可配置（默认 200 条），超过时淘汰最旧的
- 数据持久化（重启后保留）

**边界情况：**
- 连续多次复制相同内容只记录一次（去重）
- 应用未启动期间的剪贴板变化不记录（不尝试追溯）
- 敏感应用（如密码管理器）复制的内容仍会被记录（后续考虑排除列表）
- 超大文本（如 1MB+）只保存前 N 个字符的预览，不保存完整内容

---

### F06：文件搜索

**WenZi 参考实现：**
- `src/wenzi/scripting/sources/file_source.py`（403 行）
  - `FileSource` 类 (L184-310)：文件搜索；`FolderSource` 类 (L312-397)：文件夹搜索
  - 图标缓存：按文件扩展名缓存到磁盘 + 内存 (L90-128)，32×32 PNG，预热常见扩展名 (L204-212)
  - 路径展示：父目录用 `~` 替代用户目录前缀
  - 类型标签 (L150-181)：根据扩展名映射为 "PDF" / "Image" / "Markdown" 等
- `src/wenzi/scripting/sources/_mdquery.py`（225 行）
  - MDQuery C API 绑定 (L20-128)：通过 ctypes 调用 CoreServices 的 `MDQueryCreate` / `MDQueryExecute` / `MDQueryGetResultCount` / `MDItemCopyAttribute`
  - `mdquery_search(query, content_type, max_results)` (L135-225)：构建 `kMDItemFSName == "*query*"cd` 查询，同步执行，服务端限制结果数量
  - 查询字符串转义 (L148-152)：处理 `\` / `"` / `*`

**需求：**
- 前缀 `f` 激活
- 基于 Spotlight 索引（NSMetadataQuery）搜索文件
- 搜索范围：用户主目录及其子目录，排除系统目录和隐藏目录
- 搜索字段：文件名（kMDItemFSName）
- 结果展示：文件图标、文件名、所在目录路径
- 回车执行默认动作：用默认应用打开文件
- Cmd+Enter：在 Finder 中显示（reveal）
- 结果数量上限：20 条
- 异步搜索，带去抖（200ms）和超时（5s）

**边界情况：**
- Spotlight 索引不可用时（如用户禁用了索引），给出友好提示
- 查询过短（如 1 个字符）时不发起搜索，避免返回过多无用结果
- 搜索进行中时用户修改了查询，取消旧查询
- 结果中的路径使用 `~` 替代完整的用户目录前缀，便于阅读

---

### F07：系统命令源

**WenZi 参考实现：**
- WenZi 没有专门的系统命令源，相关功能分散在：
  - `src/wenzi/scripting/sources/command_source.py`（221 行）：通用命令面板，`>` 前缀，用户通过 `wz.chooser.register_command()` 注册命令
  - `src/wenzi/scripting/sources/system_settings_source.py`（519 行）：macOS 系统设置面板，通过 URL scheme 打开各个设置页
  - `src/wenzi/scripting/api/execute.py`：通用 Shell 命令执行器
- 系统操作（锁屏/休眠等）通常通过 `osascript` 或直接调用系统 API 实现，需要 LingXi 自行设计

**需求：**
- 前缀 `>` 激活
- 提供一组内置系统命令，包括但不限于：
  - 锁定屏幕
  - 休眠
  - 重启
  - 关机
  - 清空废纸篓
  - 打开系统偏好设置（各个面板）
  - 退出当前应用（Quit frontmost app）
  - 强制退出（Force Quit）
  - 切换深色/浅色模式
  - 屏幕截图
  - 显示/隐藏桌面
- 每条命令有：名称、描述（作为副标题）、图标（SF Symbol）、确认要求
- 危险操作（如关机、重启、清空废纸篓）需要二次确认
- 命令列表支持模糊搜索过滤

**边界情况：**
- 需要管理员权限的操作（如关机）应通过系统标准授权流程，不自行提权
- 命令执行失败时（如权限不足），给出提示而非静默失败

---

### F08：书签搜索

**WenZi 参考实现：**
- `src/wenzi/scripting/sources/bookmark_source.py`（557 行）
  - `BookmarkSource` 类：支持 6 种浏览器
  - Chrome/Edge/Brave/Arc (L74-153)：JSON 格式，递归遍历 `bookmark_bar` / `other` / `synced` 节点，支持多 Profile
  - Safari (L163-214)：二进制 plist 解析（`plistlib`），跳过 ReadingList，需 Full Disk Access 权限
  - Firefox (L223-309)：SQLite 数据库（`places.sqlite`），JOIN `moz_bookmarks` + `moz_places`，复制临时文件避免锁冲突
  - `Bookmark` 数据类 (L29-59)：name/url/folder_path/browser/profile，懒解析 domain
  - 图标缓存 (L357-414)：从 `NSWorkspace` 获取浏览器图标，缓存为 32×32 PNG
  - 搜索 (L490-517)：多字段模糊匹配（name/domain/folder_path/browser_label）
  - 去重：按 (url, profile) 元组去重 (L83-84)

**需求：**
- 无前缀，混合在默认搜索结果中（优先级低于应用）
- 支持读取 Safari 书签（解析 ~/Library/Safari/Bookmarks.plist）
- 支持读取 Chrome 书签（解析 ~/Library/Application Support/Google/Chrome/Default/Bookmarks）
- 搜索字段：书签标题、URL
- 结果展示：网站图标（favicon，可降级为通用浏览器图标）、标题、URL
- 回车执行默认动作：在默认浏览器中打开 URL
- 书签数据缓存，不每次搜索都重新读取文件；监听文件变化或定时刷新

**边界情况：**
- 用户未安装 Chrome 时只读取 Safari 书签，反之亦然
- 书签文件格式变化或不可读时静默跳过
- 书签中存在重复 URL 时去重
- 书签数量极大时（如 5000+），搜索仍需保持快速响应

---

## P2：交互增强

### F09：修饰键动作 ✅

**现状：** 目前只有 Enter 一种执行方式，没有二级动作。

**WenZi 参考实现：**
- `src/wenzi/scripting/sources/__init__.py`
  - `ModifierAction` 数据类 (L51-55)：包含 subtitle（动作描述）和 action（可选回调）
  - `ChooserItem.modifiers` (L71-74)：`Dict[str, ModifierAction]`，键为 "cmd" / "alt" / "ctrl"
- `src/wenzi/scripting/ui/chooser_panel.py`
  - `_execute_item()` (L1436-1495)：根据传入的 modifier 参数查找 `item.modifiers[modifier]`，有则执行修饰动作
  - `_action_hints_to_modifier_map()` (L1000-1006)：将源的 action_hints 转为 modifier→label 映射
- `src/wenzi/ui/templates/chooser.html`
  - `_getActiveModifier()` (L828-831)：检测当前按住的修饰键
  - `setModifierHints()` (L929)：更新 UI 中的修饰键动作提示文字
  - keydown/keyup 事件 (L826-858)：追踪修饰键状态，动态切换副标题

**需求：**
- 每个搜索结果可以关联多个动作，由修饰键区分：
  - Enter：默认动作
  - Cmd+Enter：二级动作（如"在 Finder 中显示"、"复制路径"）
  - Alt+Enter：第三动作（由具体源定义）
- 按住修饰键时，结果行的副标题区域动态切换为对应动作的描述
- 松开修饰键后恢复原始副标题
- 源在注册时声明自己支持哪些修饰键动作及其描述

**边界情况：**
- 结果项未定义某个修饰键动作时，按该组合键无反应
- 修饰键按住期间切换选中项，新选中项也应显示对应的修饰键描述

---

### F10：Tab 补全

**WenZi 参考实现：**
- `src/wenzi/scripting/ui/chooser_panel.py`
  - `_handle_tab_complete()` (L1354-1387)：获取当前激活的前缀源，调用 `source.complete(stripped_query, item)`，返回值通过 JS `setInputValue()` 写回输入框
- `src/wenzi/scripting/sources/__init__.py`
  - `ChooserSource.complete` (L101-104)：`Callable[[str, ChooserItem], Optional[str]]`，接收查询和选中项，返回补全后的查询字符串
- `src/wenzi/ui/templates/chooser.html`
  - Tab 键处理 (L754-757)：拦截 Tab，发送 `{type: 'tab', index: selectedIndex}` 到 Python

**需求：**
- 按 Tab 键触发当前源的补全逻辑
- 补全行为由源定义，典型场景：
  - 文件搜索中：Tab 补全为选中结果的路径，继续搜索其子目录
  - 前缀提示中：Tab 补全为该前缀 + 空格，激活对应源
- 补全后光标保持在输入框末尾，用户可继续输入
- 若当前源未定义补全逻辑，Tab 键无操作

---

### F11：查询历史 ✅

**WenZi 参考实现：**
- `src/wenzi/scripting/sources/query_history.py`（120 行）
  - `QueryHistory` 类 (L27-120)
  - `record(query)` (L56)：去重并追加到列表头部
  - `entries()` (L76)：返回最近优先的列表
  - 持久化：JSON 数组存储在 `~/.local/share/WenZi/chooser_history.json`
  - `_schedule_flush()` / `_flush()` (L90-120)：延迟 2 秒批量写入，与 UsageTracker 相同策略
- 集成：`chooser_panel.py` L1463-1464 在执行选中项时记录查询；HTML 中 ↑↓ 键在空输入时触发 `historyUp` / `historyDown` 消息

**需求：**
- 记录用户执行过的查询（按 Enter 确认过的查询）
- 搜索框为空时，按 ↑ 键浏览历史查询（从最近到最早）
- 按 ↓ 键回到更近的查询，到底后恢复空输入框
- 历史记录持久化到本地
- 历史容量上限（默认 100 条）
- 相同查询不重复记录，但将其移动到最近位置

**边界情况：**
- 搜索框非空时，↑↓ 键仍为结果列表导航，不触发历史浏览
- 浏览历史过程中修改了文本，退出历史模式，进入正常搜索

---

### F12：Quick Look 预览

**WenZi 参考实现：**
- `src/wenzi/scripting/ui/quicklook_panel.py`（213 行）
  - `QuickLookPanel` 类 (L19-213)
  - `show(path, anchor_panel)` (L64)：显示 QLPreviewPanel 单例
  - `update(path)` (L77)：切换选中项时更新预览内容（`reloadData()`）
  - `close()` (L83)：隐藏并清理
  - `_install_key_monitor()` (L154-201)：本地事件监听器检测 Shift 单独短按（<0.4s）触发切换
  - `QuickLookDataSource` (L221-244)：实现 `QLPreviewPanelDataSource`，提供单个 NSURL
  - 面板配置 (L139-143)：`NSStatusWindowLevel + 1`，浮动，跨 Space
- 集成：`chooser_panel.py` L1507 通过 `_toggle_quicklook()` 调用

**需求：**
- 对文件类型的搜索结果，支持 Quick Look 预览
- 触发方式：选中文件结果后按空格键（与 Finder 一致）
- 预览面板锚定在搜索面板旁边显示
- 按 ↑↓ 切换选中项时，预览内容跟随更新
- 再次按空格键或按 Esc 关闭预览
- 非文件类型的结果不响应空格键预览

**边界情况：**
- 文件已被删除或不可访问时，预览面板显示错误提示
- 切换到非文件结果时自动关闭预览面板
- 预览面板不应遮挡搜索面板的核心区域

---

## P3：可扩展性

### F13：插件系统

**WenZi 参考实现：**
- `src/wenzi/scripting/engine.py`
  - `_load_plugins()` (L839-957)：扫描 `~/.config/WenZi/plugins/` 子目录，每个目录需含 `__init__.py` + `setup(wz)` 入口函数
  - 通过 `importlib.import_module()` 动态加载，调用 `setup(wz)` 传入 API 命名空间
  - 支持 `disabled_plugins` 配置项禁用，`min_wenzi_version` 版本兼容检查
  - 加载错误记录到 `_plugin_load_errors` 字典，不影响主应用
- `src/wenzi/scripting/plugin_meta.py`（71 行）
  - `PluginMeta` 数据类 (L15-71)：name/id/description/version/author/url/icon/min_wenzi_version
  - `load_plugin_meta(plugin_dir)` (L30)：读取插件目录下的 `plugin.toml` 元数据文件
- 示例插件：`plugins/window_switcher/__init__.py`
  - `setup(wz)` 中通过 `@wz.chooser.source()` 装饰器注册搜索源

**需求：**
- 定义标准的插件协议，第三方可以开发自定义搜索源
- 插件以 macOS Bundle (.bundle) 形式分发
- 插件目录：`~/Library/Application Support/LingXi/Plugins/`
- 应用启动时自动扫描并加载插件目录中的所有合法插件
- 每个插件需声明：
  - 名称、描述、版本
  - 搜索前缀（可选）
  - 搜索方法（同步或异步）
  - 支持的动作和修饰键
- 插件可访问的 API：剪贴板操作、通知、打开 URL、执行 Shell 命令（需用户授权）
- 插件崩溃不影响主应用（进程隔离或异常捕获）
- 提供插件管理界面：查看已加载插件、启用/禁用、卸载

**安全考虑：**
- 插件执行 Shell 命令需用户逐次或逐插件授权
- 插件不应能访问其他插件的数据
- 考虑插件签名验证机制（远期）

---

### F14：Universal Action

**WenZi 参考实现：**
- `src/wenzi/controllers/universal_action_controller.py`（190+ 行）
  - `UniversalActionController` 类 (L20+)
  - `trigger()` (L27)：快捷键回调，后台线程调用 `get_selected_text()` 获取选中文本，再回到主线程
  - `_show_ua_panel(text)` (L43)：创建临时 `ChooserSource`，注册到 chooser，以独占模式显示面板
  - `_build_action_items()` (L92-190+)：收集可用动作（内置增强、UA 命令、UA 源）
  - 关闭时自动注销临时源 (L81-82)
- `src/wenzi/input.py`：`get_selected_text()` 通过模拟 Cmd+C 获取选中文本
- 快捷键绑定：`engine.py` 中 `_bind_universal_action_hotkey()`，配置项 `universal_action_hotkey`

**需求：**
- 通过独立快捷键触发（如 Cmd+Shift+U）
- 触发时获取当前选中的文本（通过模拟 Cmd+C 或 Accessibility API）
- 搜索面板顶部显示上下文块：展示选中的文本内容（只读，不可编辑）
- 搜索范围切换为"对此文本可执行的动作"，而非常规搜索
- 内置动作包括但不限于：
  - 在浏览器中搜索（Google/百度等，可配置）
  - 翻译（调用系统翻译或第三方服务）
  - 复制为大写/小写/首字母大写
  - Base64 编码/解码
  - URL 编码/解码
  - JSON 格式化
  - 字数/字符数统计
- 第三方插件也可以注册 Universal Action
- 回车执行选中的动作，结果根据动作类型处理（复制到剪贴板、在浏览器打开等）

**边界情况：**
- 无法获取选中文本时（如当前应用不支持），显示提示
- 选中文本过长时截断显示，但完整传递给动作
- 选中内容为图片或文件时（远期扩展），显示对应的可用动作

---

## P4：体验打磨

### F15：UI 美化

**WenZi 参考实现：**
- `src/wenzi/ui/templates/chooser.html`
  - CSS 变量 (L6-32)：`prefers-color-scheme` 媒体查询实现深色/浅色自适应
  - 虚拟滚动 (L508-595)：仅渲染可见行 + 5 行缓冲，`requestAnimationFrame` 平滑滚动
  - 结果行布局 (L160-250)：flex 布局，图标 + 标题/副标题 + 动作提示
- WenZi 使用 WKWebView 渲染 UI；LingXi 使用 SwiftUI 原生渲染，视觉效果（毛玻璃、动画）可利用 SwiftUI 原生能力（`.background(.ultraThinMaterial)`、`.animation()`）

**需求：**
- 搜索面板采用毛玻璃（vibrancy）背景效果
- 面板显示/隐藏带平滑动画（淡入淡出 + 轻微缩放）
- 搜索结果列表切换时有过渡动画
- 自适应系统深色/浅色模式
- 搜索框输入时匹配字符高亮显示（依赖 F01 的匹配位置信息）
- 搜索结果按源分组时，显示分组标题（可选）
- 空状态设计：无结果时显示友好的提示文案

---

### F16：设置界面

**WenZi 参考实现：**
- `src/wenzi/ui/settings_window_web.py` + `src/wenzi/ui/templates/settings_window_web.html`（3080 行）
  - WenZi 使用 WKWebView 渲染设置界面；LingXi 应使用 SwiftUI 原生 Settings 窗口
- `src/wenzi/controllers/settings_controller.py`：设置面板的回调处理（插件管理、快捷键录制等）
- `src/wenzi/config.py`
  - `DEFAULT_CONFIG` (L259-376)：所有配置项的默认值和结构定义
  - 配置文件路径：`~/.config/WenZi/config.json`
  - 包含 chooser.hotkey、source hotkeys、外观、剪贴板容量等配置项

**需求：**
- 提供偏好设置窗口，可从菜单栏图标打开
- 可配置项：
  - 全局快捷键：自定义呼出面板的快捷键组合
  - 开机自启动
  - 搜索结果数量上限
  - 各数据源的启用/禁用
  - 各数据源的快捷键
  - 剪贴板历史容量
  - 外观：跟随系统 / 始终深色 / 始终浅色
- 设置持久化到本地配置文件
- 修改快捷键后立即生效，无需重启

---

### F17：快捷键可配置

**现状：** 全局快捷键硬编码为 ⌥Space。

**WenZi 参考实现：**
- `src/wenzi/hotkey.py`
  - `_KEYCODE_MAP` (L22-30)：普通键 → 虚拟键码映射
  - `_SPECIAL_VK` (L31-49)：F 键、特殊键映射
  - `_MOD_VK` (L50-55)：修饰键 → (keycode, CGEventFlags) 映射
- `src/wenzi/scripting/api/hotkey.py`（150+ 行）
  - `HotkeyAPI.bind(hotkey_str, callback)` (L41)：解析字符串（如 "cmd+space"）并注册全局快捷键
  - `remap(source, target)` (L56)：按键重映射
  - Leader-key 支持 (L96+)：序列快捷键
- `src/wenzi/scripting/engine.py`
  - `_bind_chooser_hotkey()` (L694-702)：从配置读取快捷键字符串并绑定
  - `rebind_chooser_hotkey()` (L465-472)：运行时重新绑定，无需重启
  - `_bind_source_hotkeys()` (L704-722)：为各数据源绑定独立快捷键

**需求：**
- 在设置界面中提供快捷键录制组件：用户按下组合键即可设置
- 支持为以下功能绑定独立快捷键：
  - 呼出搜索面板（主快捷键）
  - 呼出剪贴板历史（直接进入 `cb` 模式）
  - 触发 Universal Action
  - 呼出文件搜索（直接进入 `f` 模式）
- 检测快捷键冲突：与系统或其他已注册快捷键冲突时提示用户
- 快捷键配置持久化，重启后自动恢复

**边界情况：**
- 用户设置了无效的快捷键组合（如单个字母键），给出提示
- 用户清除了主快捷键，面板仍可通过菜单栏图标呼出

---

## 功能依赖关系

```
F01 模糊匹配 ──────────────────────────┐
F02 使用频率 ──────────────────────────┤
F03 异步增量搜索 ──────────────────────┤── 基础能力，其他功能依赖
                                       │
F04 计算器 ─────── 依赖 F03            │
F05 剪贴板历史 ── 依赖 F03            │
F06 文件搜索 ──── 依赖 F03            │
F07 系统命令 ──── 依赖 F03            │
F08 书签搜索 ──── 依赖 F03            │
                                       │
F09 修饰键动作 ── 独立，但需各源适配   │
F10 Tab 补全 ──── 依赖 F06（典型场景） │
F11 查询历史 ──── 独立                 │
F12 Quick Look ── 依赖 F06            │
                                       │
F13 插件系统 ──── 依赖 F03、F09        │
F14 Universal Action ── 依赖 F13      │
                                       │
F15 UI 美化 ──── 依赖 F01（高亮）     │
F16 设置界面 ──── 独立                 │
F17 快捷键配置 ── 依赖 F16            │
```

## 建议实施顺序

1. **F01** → **F02** → **F03**（核心基础，按顺序）
2. **F04**、**F07**、**F11**（简单独立的源和功能，可并行开发）
3. **F06** → **F10**、**F12**（文件搜索及其衍生交互）
4. **F05**、**F08**（更复杂的数据源）
5. **F09**（修饰键动作，需要各源配合适配）
6. **F15**、**F16** → **F17**（体验打磨）
7. **F13** → **F14**（插件系统，最复杂，放在最后）
