# 阶段三：搜索功能 — 分步计划

## 目标

将模拟数据替换为真实搜索能力：搜索并启动已安装应用、搜索并打开文件、按匹配度排序结果。

---

## Step 1：扩展数据模型 + 搜索协议

**改动：**
- `SearchResult` 新增字段：`resultType: SearchResultType`（枚举：`.application` / `.file`）、`url: URL?`（应用或文件的实际路径）、`score: Double`（匹配分数，用于排序）
- 将 `icon: String`（SF Symbol 名）改为 `icon: NSImage?`，以支持真实应用图标
- 新建 `Search/SearchProvider.swift`，定义协议：
  ```swift
  protocol SearchProvider {
      func search(query: String) async -> [SearchResult]
  }
  ```
- 将现有模拟数据搜索逻辑提取为 `MockSearchProvider` 实现此协议，确保已有功能不受影响
- 更新 `SearchViewModel` 使用 `SearchProvider` 协议
- UI 层适配 `NSImage?` 图标显示（`Image(nsImage:)` 替代 `Image(systemName:)`）
- 更新已有测试以适配新模型

**验证：**
- [ ] 编译通过，已有测试全部通过
- [ ] 呼出面板，输入文字，行为与改动前完全一致（模拟数据仍生效）
- [ ] 结果行正确显示图标、名称、副标题

---

## Step 2：应用搜索

**改动：**
- 新建 `Search/ApplicationSearchProvider.swift`
- 扫描 `/Applications`、`/System/Applications`、`~/Applications` 目录下的 `.app` 包
- 使用 `NSWorkspace.shared.icon(forFile:)` 获取应用图标
- 使用 `Bundle(url:)` 读取应用的显示名称（`CFBundleDisplayName` / `CFBundleName`）
- 启动时预加载应用列表缓存，搜索时对缓存进行本地过滤
- 在 `SearchViewModel` 中用 `ApplicationSearchProvider` 替换 `MockSearchProvider`

**验证：**
- [ ] 呼出面板，输入"Safari"，出现 Safari 结果，图标为真实 Safari 图标
- [ ] 输入"Terminal"，出现终端应用
- [ ] 输入"System"，出现系统设置等系统应用
- [ ] 输入无效字符串（如"zzzzz"），无结果显示
- [ ] 单元测试覆盖：空查询、有匹配、无匹配、大小写不敏感

---

## Step 3：启动应用

**改动：**
- `SearchViewModel.confirm()` 中，根据 `resultType` 执行不同操作：
  - `.application`：调用 `NSWorkspace.shared.open(url)` 启动应用
- 启动后自动隐藏面板（通过回调通知 `PanelManager`）

**验证：**
- [ ] 搜索"Calculator"，回车，计算器应用被打开
- [ ] 搜索"Safari"，按 ↓ 选中后回车，Safari 被打开
- [ ] 应用启动后面板自动隐藏
- [ ] 再次按 `⌥ Space` 呼出面板，输入框已清空

---

## Step 4：文件搜索

**改动：**
- 新建 `Search/FileSearchProvider.swift`
- 使用 `NSMetadataQuery` 查询 Spotlight 索引，搜索文件名匹配的文件
- 查询范围：`kMDItemFSName` 的 `like` 匹配，限制返回数量（如 20 条）
- 从查询结果中提取：文件名、路径、图标（`NSWorkspace.shared.icon(forFile:)`）
- 设置搜索超时，防止查询卡住

**验证：**
- [ ] 输入一个已知存在的文件名片段（如"readme"），搜索结果中出现对应文件
- [ ] 结果显示文件图标、文件名、文件路径（作为 subtitle）
- [ ] 结果数量不超过上限
- [ ] 输入无效字符串，无文件结果
- [ ] 单元测试覆盖 `NSMetadataQuery` 结果解析逻辑

---

## Step 5：打开文件

**改动：**
- `SearchViewModel.confirm()` 中添加 `.file` 分支：
  - 调用 `NSWorkspace.shared.open(url)` 用默认应用打开文件
- 打开后自动隐藏面板

**验证：**
- [ ] 搜索一个文本文件，回车后文件在默认编辑器中打开
- [ ] 搜索一个图片文件，回车后在预览中打开
- [ ] 打开后面板自动隐藏
- [ ] 应用搜索和文件搜索的启动/打开行为互不干扰

---

## Step 6：合并结果 + 匹配度排序

**改动：**
- `SearchViewModel` 同时调用 `ApplicationSearchProvider` 和 `FileSearchProvider`，合并结果
- 实现匹配度评分规则：
  - 精确前缀匹配 > 包含匹配
  - 应用结果默认优先于文件结果（加权）
- 合并结果按 `score` 降序排列
- 应用搜索结果和文件搜索结果去重（同一个 .app 不重复出现）
- 添加防抖机制（如 150ms），避免高频查询

**验证：**
- [ ] 输入"Safari"，应用结果排在文件结果之前
- [ ] 输入"test"，出现应用和文件的混合结果，应用在前
- [ ] 快速连续输入不卡顿，结果实时更新
- [ ] 方向键导航在混合结果中正常工作
- [ ] 回车对应用执行启动，对文件执行打开

---

## 完成标准

阶段三完成后，应用表现为：
1. 输入文字可搜索到真实已安装的应用程序和文件
2. 搜索结果按匹配度排序，应用优先
3. 回车可启动应用或打开文件，执行后面板自动隐藏
4. 搜索响应流畅，有防抖处理
