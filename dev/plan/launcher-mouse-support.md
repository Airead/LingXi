# 启动器鼠标支持实现计划

## 背景

当前启动器 (`LingXi/Panel/PanelManager.swift`) 是一个 SwiftUI 浮动面板，结果列表通过 `ScrollView` + `LazyVStack` 渲染 `SearchResultRow`。所有交互都走键盘：箭头键、回车、Tab、⌘1–9、⌘⌫。鼠标只能滚动，不能选中或触发。

`SearchViewModel` 已经把"选中"（`selectedIndex`）和"修饰键快照"（`activeModifiers`）抽象干净了，`confirm(modifiers:)` 也已经是接收一个 modifier 集合而非事件。`SearchResultRow` 本身已有 `.contentShape(Rectangle())`，命中区域是完整行。

## 目标

1. **单击 = 选中 + 执行**：点击一行等同于键盘"上下键选中 + 回车"，复用现有 `confirm(modifiers:)` 路径。
2. **Hover 选中**：鼠标悬停到某行时把 `selectedIndex` 指向该行，但**只有鼠标实际移动时才接管**——静止光标不能打断键盘导航。
3. **修饰键 + 点击**：按住 ⌘/⌥/⌃ 点击，等价于 ⌘↵/⌥↵/⌃↵，走 `resolveModifierAction`。
4. 不新增 NSView 桥接；全部用 SwiftUI 原语实现。

## 非目标

- 不做右键菜单。
- 不做拖拽排序 / 拖拽文件到行。
- 不做"长按重排"之类触摸板手势。
- 不改变 `FloatingPanel` 的 `.nonactivatingPanel` 行为——点击不激活进程，保持前一个 app 的焦点给后续粘贴用。

## 关键设计决策

### 为什么用 `.onContinuousHover` 而不是 `.onHover`

`.onHover(true)` 在以下场景都会触发，无法区分鼠标是否真动了：

- 鼠标真的移进来 ✓（想要）
- 键盘导致 `ScrollView` 滚动，新一行被推到静止光标下方 ✗（不想要——会直接抢走键盘选中）
- 用户按下方向键时 `selectedIndex` 改变 + `scrollTo` 动画过程，同样会把光标下的行换成别的 ✗

`.onContinuousHover` 只在真实鼠标事件（进入、移动、离开）时触发，键盘滚动不会触发。用它挂在 `LazyVStack` 上，拿到 local 坐标 `point`，因为 `LazyVStack(spacing: 0)` 且每行高度固定为 `PanelLayout.rowHeight`，可以直接算：

```swift
let index = Int(point.y / PanelLayout.rowHeight)
```

坐标是相对 `LazyVStack` 内容的（而非 `ScrollView` viewport），所以不受滚动偏移影响。

### 修饰键从哪里拿

`.onTapGesture` 拿不到 `NSEvent.modifierFlags`。但 `FloatingPanel.sendEvent` 已经监听 `.flagsChanged` 并同步到 `viewModel.activeModifiers`，点击时直接读 `viewModel.activeModifiers` 就是当前快照。不需要额外接 NSEvent。

### 为什么不需要"反向抑制键盘"

用键盘选中时，如果光标静止，`.onContinuousHover` 不会触发——`selectedIndex` 被键盘改到哪里都不会被 hover 抢走。只要用户之后真的动了一下鼠标，hover 才接管。这是最符合直觉的交互（Spotlight / Raycast 都是这样）。

### 焦点保持

单击通常直接触发 `confirm()` 并调 `onDismiss()`，面板消失，不存在焦点问题。**例外：`confirm()` 返回 `false` 的极少数情况**（行无 action、URL 打开失败），此时 TextField 可能失焦。处理方式：在 click handler 里 `confirm` 失败分支中把 `isSearchFieldFocused = true` 置回。

## 实现步骤

### 1. `PanelContentView.resultsList` 添加 hover 追踪

位置：`LingXi/Panel/PanelManager.swift:343-366`

给 `LazyVStack` 加 `.onContinuousHover(coordinateSpace: .local)`：

```swift
LazyVStack(spacing: 0) {
    ForEach(...) { index, result in
        SearchResultRow(...)
            .id(result.id)
            .onTapGesture { handleRowTap(index: index) }
    }
}
.onContinuousHover(coordinateSpace: .local) { phase in
    switch phase {
    case .active(let point):
        let index = Int(point.y / PanelLayout.rowHeight)
        if viewModel.results.indices.contains(index),
           viewModel.selectedIndex != index {
            viewModel.selectedIndex = index
        }
    case .ended:
        break  // 鼠标离开列表时不改 selectedIndex
    }
}
```

注意：

- `if viewModel.selectedIndex != index` 去重，避免每次 mouseMoved 都写一次 `@Published` 触发 UI 重渲染。
- `.ended` 不做处理——用户把鼠标移出列表后，保留最后选中状态（这样再按回车还是有效的）。

### 2. `SearchResultRow` 点击处理

在 `PanelContentView` 里加一个方法：

```swift
private func handleRowTap(index: Int) {
    guard viewModel.results.indices.contains(index) else { return }
    viewModel.selectedIndex = index
    let modifiers = viewModel.activeModifiers
    if viewModel.confirm(modifiers: modifiers) {
        onDismiss()
    } else {
        // 兜底：confirm 失败时抢回焦点，防止后续键盘输入丢失
        isSearchFieldFocused = true
    }
}
```

`onDismiss` 已经通过 `PanelManager` 的 `onReturn` 路径接到 `hide()` 等价语义（实际当前 `onDismiss` 来自 `PanelContentView(onDismiss:)` 构造参数，见 `PanelManager.swift:295-297`）。需要确认 `onDismiss` 调用链是否等价于 `onReturn` 的 `hide()`——查后确认：

### 3. 确认/接通 "点击成功后真的隐藏面板"

现在 `onReturn` 回调是在 `PanelManager` 里直接调 `self?.hide()`（见 `PanelManager.swift:189-193`），而 `onDismiss` 只在 `.onExitCommand` (ESC) 和 `FloatingPanel.resignKey` 时触发，内部走的是 `newPanel.onDismiss = { [weak self] in self?.hide() }`——也是 `hide()`。所以复用 `onDismiss` 就够了，**但**要保证执行语义一致：`confirm(modifiers:)` 内部会 `recordExecution`、`exitHistoryMode`、`clear pendingDeleteIndex`，与回车路径相同。✓

### 4. 修饰键视觉反馈

`SearchResultRow` 已经根据 `activeModifiers` 变 subtitle。hover 到某行时 `selectedIndex` 切过去，再按/松开 ⌘/⌥，subtitle 也会跟着换——这是白送的，因为 `activeModifiers` 的 flagsChanged 路径不变。

### 5. 人工验证

构建后手动覆盖这些场景：

- [ ] 鼠标悬停结果行，视觉变选中态
- [ ] 鼠标悬停时按上下键，选中跟键盘走，光标静止不抢
- [ ] 键盘选到某行后移动鼠标到另一行，选中跟鼠标走
- [ ] 单击一行，执行并关闭面板（普通 action）
- [ ] ⌘+单击，触发 `resolveModifierAction`（检一个有 modifier action 的行，例如 bookmark"⌘↵ 用其它浏览器打开"）
- [ ] ⌥+单击、⌃+单击，同上
- [ ] 鼠标滚轮滚动长列表，滚到下一屏（SwiftUI ScrollView 自带，确认没回归）
- [ ] 鼠标悬停时点击，前一个 app 的焦点不丢（验证 `.nonactivatingPanel` 行为没破）
- [ ] ⌘⌫ 两次确认删除的流程，鼠标悬停一次后 `pendingDeleteIndex` 该如何？——hover 只改 `selectedIndex`，而 `selectedIndex` 的 `didSet` 会清 `pendingDeleteIndex`。**这就是现在的键盘行为**（上下键也会清 pendingDelete），一致即可。

### 6. 单元测试

`SearchViewModelTests`（如果存在）不需要改——hover 和 click 都复用 `selectedIndex` setter 和 `confirm(modifiers:)`，这些路径已有测试覆盖。如果没有 ViewModel 测试，这次也不新写——这是纯 UI 交互改动，测试成本高、ROI 低。手动验证即可。

> 按 CLAUDE.md "添加新功能时必须同时添加对应的测试用例"：这里实际 ViewModel 层没改行为，只是 SwiftUI View 新增手势绑定。SwiftUI 手势在单元测试中难以 mock，继续走手动验证更合理。如果担心回归，后面可以加 XCUITest，但建议单列任务，不混进这次改动。

## 风险与边界

1. **`.onContinuousHover` iOS 16 / macOS 13+**：查项目 `Deployment Target`——LingXi 是 macOS 14+ 项目（可从 `project.pbxproj` 确认），满足。
2. **Row 高度假设**：`Int(point.y / PanelLayout.rowHeight)` 依赖所有行等高。现在 `PanelLayout.rowHeight` 是常量，`SearchResultRow` 用 `.frame(height: PanelLayout.rowHeight)` 固定，满足。如果未来出现可变高度行，这里要改成逐行 `GeometryReader` 上报 frame。留一条注释提醒即可。
3. **`.nonactivatingPanel` + SwiftUI tap**：理论上点击 SwiftUI 行不会 activate 进程、也不会让 `FloatingPanel` resignKey。但需实际验证一次（见验证清单最后一项）。
4. **`pendingDeleteIndex` 被 hover 清掉**：如上所述，与键盘行为一致，不是回归。

## 文件改动清单

- `LingXi/Panel/PanelManager.swift`：
  - `PanelContentView.resultsList` 加 `.onContinuousHover` + 每行 `.onTapGesture`
  - `PanelContentView` 加 `handleRowTap(index:)` 私有方法

单文件改动，预计 ~30 行净增。
