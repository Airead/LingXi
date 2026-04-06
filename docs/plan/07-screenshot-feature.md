# 截图功能设计方案

> 参考项目：[Snapzy](https://github.com/duongductrong/Snapzy)（BSD-3 许可证）
> 项目位置：/Users/fanrenhao/work/Snapzy

## 功能概述

为 LingXi 添加截图功能，支持全屏截图、区域选择截图、窗口截图，以及截图后的标注编辑。用户可通过全局快捷键触发截图，完成后将结果保存到文件或复制到剪贴板。

## 技术选型

| 组件 | 技术 | 说明 |
|------|------|------|
| 屏幕捕获 | ScreenCaptureKit | macOS 14+ 原生框架，支持窗口/屏幕/区域捕获 |
| 区域选择 UI | AppKit (NSPanel + CALayer) | 高性能叠加层，60fps 实时渲染 |
| 标注画布 | AppKit (NSView + CGContext) | 性能关键路径使用原生绘制 |
| 标注 UI | SwiftUI | 工具栏、侧边栏等 UI 布局 |
| 模糊/马赛克 | Core Image (CIFilter) | CIPixellate / CIGaussianBlur |
| 文字识别 | Vision (VNRecognizeTextRequest) | 可选的 OCR 扩展 |

## 模块结构

```
LingXi/
└── Screenshot/
    ├── ScreenshotManager.swift            # 截图功能总入口，协调各模块
    ├── Capture/
    │   └── ScreenCaptureService.swift     # ScreenCaptureKit 封装（权限、捕获、裁剪）
    ├── RegionSelection/
    │   ├── RegionSelectionController.swift # 区域选择协调器（窗口池管理）
    │   ├── RegionSelectionWindow.swift     # 全屏覆盖 NSPanel
    │   └── RegionSelectionOverlayView.swift# 鼠标事件 + CALayer 渲染
    ├── Annotation/
    │   ├── Models/
    │   │   ├── AnnotationItem.swift        # 标注数据模型
    │   │   └── AnnotationTool.swift        # 工具类型枚举
    │   ├── Views/
    │   │   ├── AnnotationEditorView.swift  # 标注编辑器主视图 (SwiftUI)
    │   │   ├── AnnotationCanvasView.swift  # 绘制画布 (NSViewRepresentable)
    │   │   └── AnnotationToolbar.swift     # 工具栏 (SwiftUI)
    │   ├── State/
    │   │   └── AnnotationState.swift       # 标注编辑器状态管理
    │   ├── Services/
    │   │   ├── AnnotationRenderer.swift    # CGContext 标注渲染器
    │   │   ├── AnnotationFactory.swift     # 标注创建工厂
    │   │   ├── AnnotationHitTester.swift   # 命中测试
    │   │   └── BlurCacheManager.swift      # 模糊效果缓存
    │   └── Window/
    │       ├── AnnotationWindow.swift      # 标注编辑窗口 (NSWindow)
    │       └── AnnotationWindowController.swift
    └── Export/
        └── ImageExporter.swift             # 合成输出、保存、复制到剪贴板
```

## 分阶段实现计划

> **原则**：每个步骤产出可独立验证的成果，先跑通最简路径，再逐步增强。

---

### Phase 1：基础截图能力

**目标**：实现最基本的全屏截图和区域截图，截图结果保存到剪贴板。

#### 步骤 1.1：ScreenCaptureService — 权限检查 + 全屏截图

**涉及文件**：`Screenshot/Capture/ScreenCaptureService.swift`

核心职责：
- 权限管理（检查 + 请求屏幕录制权限）
- 全屏截图（通过 ScreenCaptureKit）
- 区域裁剪（全屏截图 + 后裁剪策略）

```swift
@MainActor
class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    /// Check and request screen capture permission
    func ensurePermission() async -> Bool

    /// Capture full screen for the specified display
    func captureFullScreen(display: SCDisplay, excludingWindows: [SCWindow]) async throws -> CGImage

    /// Crop a captured image to the specified region
    func cropImage(_ image: CGImage, to rect: CGRect, scaleFactor: CGFloat) -> CGImage
}
```

**关键实现细节**：

权限管理采用三段式策略：
1. `CGPreflightScreenCaptureAccess()` 快速检查
2. `SCShareableContent.current` 触发系统授权弹窗（macOS 14）
3. `CGRequestScreenCaptureAccess()` 引导用户到系统设置（macOS 15+）

截图策略 — **全屏捕获 + 后裁剪**：
- 先用 `SCScreenshotManager.captureImage()` 获取全屏原生分辨率截图
- 再用 `CGImage.cropping(to:)` 按像素精确裁剪
- 避免使用 `SCStreamConfiguration.sourceRect`（会触发插值导致模糊）

构建 `SCContentFilter` 时排除：
- LingXi 自身窗口
- 区域选择覆盖窗口

Retina 屏幕处理：
- 使用 `NSScreen.backingScaleFactor` 转换逻辑坐标到像素坐标
- 配置 `SCStreamConfiguration` 使用原生像素分辨率

**验证方法**：
- 单元测试覆盖权限检查逻辑和图片裁剪（含 Retina 缩放）
- 手动调用 `captureFullScreen()` 后检查剪贴板有完整屏幕图片

---

#### 步骤 1.2：RegionSelectionWindow + OverlayView — 全屏覆盖层与十字准星

**涉及文件**：
- `Screenshot/RegionSelection/RegionSelectionWindow.swift`
- `Screenshot/RegionSelection/RegionSelectionOverlayView.swift`（仅十字准星，不含选区）

```swift
class RegionSelectionWindow: NSPanel {
    // Configuration:
    // styleMask: [.borderless, .nonactivatingPanel]
    // level: .screenSaver
    // canBecomeKey: false
    // canBecomeMain: false
    // collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]
    // animationBehavior: .none
    // backgroundColor: .clear
    // isOpaque: false
}
```

关键配置说明：
- `nonactivatingPanel`：不抢焦点，背景窗口不会模糊
- `.screenSaver` level：确保覆盖所有窗口
- `canBecomeKey/Main = false`：不干扰其他应用

OverlayView 此步仅实现：
- `dimLayer`：全屏半透明黑色遮罩 (alpha: 0.3)
- `crosshairLayer`：十字准星指示器（带阴影），跟随鼠标移动
- `mouseMoved` 事件更新十字准星位置

**验证方法**：
- 手动触发显示覆盖窗口，看到半透明遮罩覆盖全屏
- 移动鼠标，十字准星实时跟随

---

#### 步骤 1.3：OverlayView — 拖拽选区与尺寸指示器

**涉及文件**：`Screenshot/RegionSelection/RegionSelectionOverlayView.swift`（扩展）

在步骤 1.2 基础上添加：

**CALayer 层结构**（完整）：
```
rootLayer
├── dimLayer              # 全屏半透明黑色遮罩 (alpha: 0.3)
├── selectionBorderLayer  # 选区白色边框
└── crosshairLayer        # 十字准星指示器（带阴影）
```

选区透明效果通过 `CAShapeLayer` mask + `evenOdd` 填充规则实现：选区内部透明（露出桌面截图），选区外部半透明遮罩。

**鼠标事件处理**：

| 事件 | 行为 |
|------|------|
| `mouseDown` | 记录起点，开始选择 |
| `mouseDragged` | 实时更新选区矩形，更新 CALayer |
| `mouseUp` | 选区 > 5×5 px 时确认，否则重置 |
| `mouseMoved` | 更新十字准星位置 |
| `rightMouseDown` | 取消选择 |

尺寸指示器：在选区右下角显示 "W×H" 像素尺寸。

性能优化：
- 所有 layer 设置 `disableActions = true`，禁用隐式动画
- `mouseDragged` 中使用 `CATransaction.setDisableActions(true)`

**验证方法**：
- 在覆盖窗口上拖拽，能看到选区框（白色边框）
- 选区内部透明露出桌面，外部保持遮罩
- 右下角显示实时尺寸数字（如 "800×600"）

---

#### 步骤 1.4：RegionSelectionController — 选区流程协调

**涉及文件**：`Screenshot/RegionSelection/RegionSelectionController.swift`

核心职责：
- 管理区域选择窗口（先支持单屏幕，窗口池优化留到 1.7）
- 协调选择流程的生命周期
- 处理 Escape 键取消

```swift
@MainActor
class RegionSelectionController {
    static let shared = RegionSelectionController()

    /// Start region selection, returns selected region in screen coordinates
    func startSelection() async -> (region: CGRect, screen: NSScreen)?

    /// Cancel current selection
    func cancelSelection()
}
```

**坐标转换**：
- View 坐标 → Window 坐标 → 全局屏幕坐标
- Cocoa 坐标系（左下原点）与屏幕坐标系转换

**验证方法**：
- 调用 `startSelection()`，完成选区后 print 出全局屏幕坐标
- 按 Escape 能取消选择，方法返回 nil
- 右键点击取消选择

---

#### 步骤 1.5：ScreenshotManager — 串联完整截图流程

**涉及文件**：`Screenshot/ScreenshotManager.swift`

```swift
@MainActor
class ScreenshotManager {
    static let shared = ScreenshotManager()

    /// Capture region screenshot (main entry point)
    func captureRegion() async

    /// Capture full screen screenshot
    func captureFullScreen() async
}
```

**完整截图流程**：
```
快捷键触发
  → ScreenshotManager.captureRegion()
    → 隐藏 LingXi 面板
    → ScreenCaptureService 预取 SCShareableContent
    → 全屏截图（作为覆盖窗口背景）
    → RegionSelectionController.startSelection()
      → 显示覆盖窗口（用截图做背景，非实时透视）
      → 用户拖拽选区
      → 返回选区坐标
    → ScreenCaptureService.cropImage() 裁剪
    → 复制到剪贴板
```

> 覆盖窗口使用截图做背景而非实时透视，避免桌面内容变化导致的视觉跳动，也是主流截图工具的通用做法。

预取优化：
- 在用户选择区域时提前调用 `SCShareableContent.current` 加载可用内容
- 选择完成后可立即执行截图，无需等待

**验证方法**：
- 触发区域截图 → 拖拽选区 → 打开"预览" app 粘贴 → 验证截图内容和区域正确
- 触发全屏截图 → 粘贴验证完整屏幕内容
- Retina 屏幕下截图清晰度正确（像素级别无模糊）

---

#### 步骤 1.6：快捷键注册 + 设置项

**涉及文件**：
- `HotKeyManager` 中注册截图快捷键
- `AppSettings` 中添加截图设置项

快捷键：
- 区域截图：默认 `⌘⇧4`（可自定义，避免与系统冲突）
- 全屏截图：默认 `⌘⇧3`（可自定义）

**验证方法**：
- 按 `⌘⇧4` 触发区域截图流程
- 按 `⌘⇧3` 触发全屏截图
- 在设置中修改快捷键后生效

---

#### 步骤 1.7：窗口池优化 + 多显示器 + 测试补全

**涉及文件**：
- `RegionSelectionController.swift`（窗口池改造）
- `ScreenCaptureServiceTests.swift`
- `RegionSelectionControllerTests.swift`
- `ScreenshotManagerTests.swift`

窗口池优化（参考 Snapzy 核心优化）：
- 应用启动时为每个屏幕预分配 `RegionSelectionWindow`
- 使用 `orderOut` / `orderFrontRegardless` 隐藏/显示，而非创建/销毁
- 监听 `NSApplication.didChangeScreenParametersNotification` 动态刷新窗口池
- 目标：选区窗口激活时间 < 150ms

测试覆盖：

| 测试文件 | 覆盖内容 |
|----------|----------|
| `ScreenCaptureServiceTests.swift` | 权限检查逻辑、图片裁剪（含 Retina 缩放）、坐标转换 |
| `RegionSelectionControllerTests.swift` | 窗口池管理、多显示器场景、选区最小尺寸验证 |
| `ScreenshotManagerTests.swift` | 截图流程协调、面板隐藏/恢复、剪贴板写入 |

**验证方法**：
- 连接外接显示器，两个屏幕都能正常截图
- 拔插显示器后窗口池自动刷新
- 全部单元测试通过

---

### Phase 2：标注编辑器

**目标**：截图完成后进入标注编辑窗口，支持常用标注工具。

#### 步骤 2.1：数据模型 — AnnotationItem + AnnotationTool + AnnotationState

**涉及文件**：
- `Screenshot/Annotation/Models/AnnotationItem.swift`
- `Screenshot/Annotation/Models/AnnotationTool.swift`
- `Screenshot/Annotation/State/AnnotationState.swift`

```swift
/// Annotation type with associated data
enum AnnotationType: Equatable {
    case rectangle(CGRect)
    case filledRectangle(CGRect)
    case ellipse(CGRect)
    case arrow(start: CGPoint, end: CGPoint)
    case line(start: CGPoint, end: CGPoint)
    case path([CGPoint])                  // Free-hand drawing
    case text(String)
    case highlight([CGPoint])             // Highlighter pen
    case blur(BlurType)                   // Pixelate or Gaussian
    case counter(Int)                     // Numbered step marker
}

enum BlurType: Equatable {
    case pixelate
    case gaussian
}

/// Visual properties for an annotation
struct AnnotationProperties: Equatable {
    var strokeColor: Color
    var fillColor: Color
    var strokeWidth: CGFloat
    var fontSize: CGFloat
    var fontName: String
}

/// A single annotation item
struct AnnotationItem: Identifiable, Equatable {
    let id: UUID
    var type: AnnotationType
    var bounds: CGRect
    var properties: AnnotationProperties
}
```

```swift
enum AnnotationTool: String, CaseIterable, Identifiable {
    case selection       // Select and move/resize annotations
    case rectangle       // Rectangle outline
    case filledRectangle // Filled rectangle
    case ellipse         // Ellipse outline
    case arrow           // Arrow
    case line            // Straight line
    case pencil          // Free-hand drawing
    case text            // Text annotation
    case highlighter     // Semi-transparent highlighter pen
    case blur            // Pixelate / Gaussian blur
    case counter         // Numbered step marker
    case crop            // Crop tool

    var id: String { rawValue }
    var icon: String { ... }        // SF Symbol name
    var shortcutKey: Character { ... }  // Keyboard shortcut
    var displayName: String { ... }
}
```

```swift
@MainActor
@Observable
class AnnotationState {
    // Image
    var sourceImage: NSImage
    var editedImage: NSImage?

    // Tool
    var selectedTool: AnnotationTool = .arrow
    var strokeColor: Color = .red
    var fillColor: Color = .clear
    var strokeWidth: CGFloat = 3.0
    var blurType: BlurType = .pixelate

    // Annotations
    var annotations: [AnnotationItem] = []
    var selectedAnnotationId: UUID?
    var editingTextAnnotationId: UUID?

    // Undo/Redo (snapshot-based)
    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []

    // Drawing state
    var isDrawing: Bool = false
    var currentPoints: [CGPoint] = []
    var drawingStartPoint: CGPoint?
    var drawingEndPoint: CGPoint?

    // Counter
    private var nextCounterNumber: Int = 1

    // Zoom & Pan
    var zoomLevel: CGFloat = 1.0    // 0.25 - 4.0
    var panOffset: CGSize = .zero

    func undo() { ... }
    func redo() { ... }
    func saveState() { ... }
    func addAnnotation(_ item: AnnotationItem) { ... }
    func deleteSelected() { ... }
}
```

**验证方法**：
- 单元测试覆盖：标注增删、undo/redo 来回切换、工具切换、计数器自增
- `AnnotationState` 的 undo/redo 在各种操作序列下状态正确

---

#### 步骤 2.2：标注编辑窗口空壳 — 截图后弹出窗口显示图片

**涉及文件**：
- `Screenshot/Annotation/Window/AnnotationWindow.swift`
- `Screenshot/Annotation/Window/AnnotationWindowController.swift`
- `Screenshot/Annotation/Views/AnnotationEditorView.swift`（空壳布局）
- `Screenshot/ScreenshotManager.swift`（修改：截图后打开编辑窗口）

**AnnotationWindow** (NSWindow 子类)：
- 自定义标题栏（透明，与编辑器融为一体）
- 此步仅展示截图图片 + 空工具栏占位

**AnnotationEditorView** (SwiftUI 主视图) 基础布局：
```
┌──────────────────────────────────────┐
│  Toolbar (placeholder)               │
├──────────────────────────────────────┤
│                                      │
│         截图图片（NSImage 显示）       │
│                                      │
├──────────────────────────────────────┤
│  Bottom bar (placeholder)            │
└──────────────────────────────────────┘
```

修改 `ScreenshotManager`：截图完成后不再直接复制到剪贴板，而是打开标注编辑窗口。

**验证方法**：
- 完成区域截图后，弹出标注编辑窗口
- 窗口中正确显示刚截取的图片
- 关闭窗口正常，无内存泄漏

---

#### 步骤 2.3：AnnotationRenderer — 基础形状渲染（矩形 + 椭圆 + 线段）

**涉及文件**：
- `Screenshot/Annotation/Services/AnnotationRenderer.swift`

纯 `CGContext` 渲染，此步实现三种基础形状：

- **矩形（描边/填充）**：`CGContext.stroke/fill` + `CGPath`
- **椭圆**：`CGContext.strokeEllipse/fillEllipse`
- **线段**：`CGContext.strokeLineSegments`

**验证方法**：
- 在 `AnnotationState` 中硬编码几个标注（矩形、椭圆、线段）
- 标注编辑窗口中能看到这些形状正确渲染在截图上方

---

#### 步骤 2.4：AnnotationCanvasView — 鼠标交互绘制基础形状

**涉及文件**：
- `Screenshot/Annotation/Views/AnnotationCanvasView.swift`
- `Screenshot/Annotation/Services/AnnotationFactory.swift`

使用 `NSViewRepresentable` 包裹 `NSView` 子类，实现高性能绘制。

**核心设计原则**：
- 所有标注坐标存储为**图像坐标系**（与显示缩放无关）
- 渲染时通过 `displayScale` 将图像坐标映射到视图坐标
- `displayToImage()` / `imageToDisplay()` 进行坐标转换

**鼠标事件**（此步仅支持 rectangle / ellipse / line）：

| 当前工具 | mouseDown | mouseDragged | mouseUp |
|----------|-----------|--------------|---------|
| rectangle/ellipse | 记录起点 | 实时预览矩形/椭圆 | 创建标注 |
| line | 记录起点 | 实时预览线段 | 创建标注 |

**`draw(_:)` 渲染流程**：
1. 应用缩放变换 (`displayScale`)
2. 绘制源图像
3. 创建 `AnnotationRenderer`，遍历所有标注进行渲染
4. 绘制当前正在进行的笔划（实时预览）

`AnnotationFactory`：根据当前工具类型和手势数据创建 `AnnotationItem`。

**验证方法**：
- 在画布上拖拽能绘制矩形、椭圆、线段
- 拖拽过程中有实时预览
- 松手后标注被添加到 `AnnotationState`
- 可以连续绘制多个标注

---

#### 步骤 2.5：AnnotationToolbar — 工具切换 + 颜色/线宽

**涉及文件**：
- `Screenshot/Annotation/Views/AnnotationToolbar.swift`
- `Screenshot/Annotation/Views/AnnotationEditorView.swift`（集成工具栏）

工具栏 UI（SwiftUI）：
- 工具按钮组（当前仅启用 rectangle / ellipse / line，其他置灰）
- 颜色选择器（预设颜色 + 自定义）
- 线宽选择器

**验证方法**：
- UI 上能看到工具栏，点击切换当前工具
- 选择红色后绘制的标注是红色
- 修改线宽后绘制的标注使用新线宽

---

#### 步骤 2.6：箭头 + 自由画笔 + 高亮笔

**涉及文件**：
- `AnnotationRenderer.swift`（扩展：箭头、画笔、高亮笔渲染）
- `AnnotationCanvasView.swift`（扩展：对应鼠标交互）
- `AnnotationFactory.swift`（扩展：对应标注创建）

新增渲染：
- **箭头**：线段 + 三角函数计算箭头尖端三角形
- **自由画笔**：`CGPath.addLines` 连接所有采样点
- **高亮笔**：同画笔，但使用半透明颜色 + 较宽线宽

新增鼠标交互：

| 当前工具 | mouseDown | mouseDragged | mouseUp |
|----------|-----------|--------------|---------|
| arrow | 记录起点 | 实时预览箭头 | 创建标注 |
| pencil/highlighter | 记录起点 | 收集路径点 | 创建路径标注 |

**验证方法**：
- 能绘制箭头（带箭头尖端三角形）
- 能自由涂鸦（平滑路径）
- 高亮笔绘制半透明宽线条
- 工具栏中对应按钮启用

---

#### 步骤 2.7：AnnotationHitTester + selection 工具

**涉及文件**：
- `Screenshot/Annotation/Services/AnnotationHitTester.swift`
- `AnnotationCanvasView.swift`（扩展：selection 模式交互）
- `AnnotationRenderer.swift`（扩展：选中态手柄渲染）

命中测试逻辑：
- **矩形**：`bounds.contains(point)` 或边框 ±tolerance 命中
- **椭圆**：椭圆方程 `(x/a)² + (y/b)² ≤ 1`
- **箭头/线段**：点到线段距离 < tolerance
- **路径**：点到折线最近距离 < tolerance

选中标注显示 8 个调整手柄，命中手柄时进入 resize 模式。

鼠标交互（selection 工具）：

| 事件 | 行为 |
|------|------|
| mouseDown | 命中测试 → 选中标注 / 命中手柄 → 开始调整 |
| mouseDragged | 移动标注 / 调整大小 |
| mouseUp | 确认位置 |

**验证方法**：
- 切换到 selection 工具后，点击已有标注能选中（显示蓝色手柄）
- 拖动选中标注能移动
- 拖动手柄能调整大小
- 点击空白处取消选中
- Delete 键删除选中标注

---

#### 步骤 2.8：文字标注 + 计数器标注

**涉及文件**：
- `AnnotationRenderer.swift`（扩展：文字、计数器渲染）
- `AnnotationCanvasView.swift`（扩展：文字/计数器交互）

新增渲染：
- **文字**：`NSAttributedString.draw(at:)` 或 `CTLineDraw`
- **计数器**：绘制带编号的圆形标记

新增交互：

| 当前工具 | mouseDown | 行为 |
|----------|-----------|------|
| text | 点击位置 | 创建可编辑文本框（NSTextField 覆盖在画布上） |
| counter | 点击位置 | 在点击处创建编号标记（自增） |

**验证方法**：
- 点击放置文字，可输入/编辑文本内容
- 文字标注支持字体大小设置
- 点击放置计数器，编号自动递增（1, 2, 3...）
- 计数器标记显示为带数字的圆形

---

#### 步骤 2.9：模糊/马赛克 + BlurCacheManager + 裁剪工具

**涉及文件**：
- `AnnotationRenderer.swift`（扩展：模糊渲染）
- `AnnotationCanvasView.swift`（扩展：模糊/裁剪交互）
- `Screenshot/Annotation/Services/BlurCacheManager.swift`

模糊/马赛克：
- `CIPixellate` 或 `CIGaussianBlur` 处理选区图像
- `BlurCacheManager` 缓存优化：
  - 首次模糊区域时计算并缓存结果
  - 交互式拖动时，如果区域变化小于阈值，复用之前的缓存
  - 区域确认后重新计算精确模糊
  - 缓存 key：区域 rect + 模糊类型 + 模糊参数

裁剪工具：

| 当前工具 | mouseDown | mouseDragged | mouseUp |
|----------|-----------|--------------|---------|
| blur | 记录起点 | 实时预览模糊区域 | 创建模糊标注 |
| crop | 记录起点 | 实时预览裁剪区域 | 应用裁剪 |

**验证方法**：
- 能框选区域做马赛克（像素化效果清晰可见）
- 能切换马赛克/高斯模糊两种模式
- 拖动过程中有实时预览（可以有延迟但不卡顿）
- 裁剪工具能裁切图片，裁剪后画布更新

---

### Phase 3：导出与集成

**目标**：完善导出功能，与 LingXi 搜索系统集成。

#### 步骤 3.1：ImageExporter — 合成渲染 + 复制到剪贴板

**涉及文件**：`Screenshot/Export/ImageExporter.swift`

```swift
struct ImageExporter {
    /// Render final image with all annotations
    static func renderFinalImage(source: CGImage, annotations: [AnnotationItem]) -> NSImage

    /// Copy to clipboard
    static func copyToClipboard(_ image: NSImage)
}
```

渲染流程：
1. 在图像坐标系创建 `CGContext`（原生分辨率）
2. 绘制源图
3. 使用 `AnnotationRenderer` 遍历渲染所有标注
4. 输出 `NSImage`

**验证方法**：
- 在标注编辑器中添加几个标注，点击"复制"
- 粘贴到其他 app（预览、微信等），标注被正确合成在截图上
- 合成图片分辨率与原图一致（不降质）

---

#### 步骤 3.2：保存到文件 + 底部操作栏

**涉及文件**：
- `Screenshot/Export/ImageExporter.swift`（扩展：文件保存）
- `Screenshot/Annotation/Views/AnnotationEditorView.swift`（底部栏 UI）

```swift
extension ImageExporter {
    /// Save to file (PNG/JPEG)
    static func saveToFile(_ image: NSImage, path: URL, format: ImageFormat) throws
}
```

支持格式：PNG（默认，保留透明度）、JPEG（可配置质量）。

底部操作栏 UI：
- 缩放滑块 / 百分比显示
- 保存按钮（触发 NSSavePanel）
- 复制到剪贴板按钮
- 格式选择（PNG / JPEG）

**验证方法**：
- 点击保存，弹出文件选择对话框，保存为 PNG/JPEG
- 保存的文件包含所有标注
- JPEG 质量可配置
- 缩放操作正常（放大/缩小画布）

---

#### 步骤 3.3：快捷键完善

**涉及文件**：
- `Screenshot/Annotation/Window/AnnotationWindow.swift`（快捷键处理）

覆写 `performKeyEquivalent` 处理快捷键：
- `⌘S`：保存
- `⌘⇧S`：另存为
- `⌘Z`：撤销
- `⌘⇧Z`：重做
- `⌘C`：复制到剪贴板
- `Delete`：删除选中标注
- 数字键 / 字母键：切换工具

覆写 `sendEvent` 处理：
- `⌘+滚轮`：缩放
- 触控板捏合：缩放
- `Space+拖动`：平移画布

**验证方法**：
- 逐一验证每个快捷键功能
- ⌘Z / ⌘⇧Z 撤销重做正确
- Space+拖动平移画布
- 捏合缩放流畅

---

#### 步骤 3.4：LingXi 搜索集成 + 设置项完善

**涉及文件**：
- LingXi 搜索系统（注册 "screenshot" 命令）
- `AppSettings`（截图设置项）
- `SettingsView`（设置 UI）

搜索集成：
- 注册 "screenshot" / "截图" 系统命令
- 用户输入时显示截图选项（区域截图、全屏截图）

设置项：

| 设置项 | 说明 | 默认值 |
|--------|------|--------|
| 截图快捷键 | 区域截图 / 全屏截图 | `⌘⇧4` / `⌘⇧3` |
| 截图后行为 | 复制到剪贴板 / 打开标注编辑器 / 保存到文件 | 复制到剪贴板 |
| 默认保存路径 | 截图文件保存目录 | ~/Desktop |
| 默认图片格式 | PNG / JPEG | PNG |
| JPEG 质量 | 0-100 | 90 |

**验证方法**：
- 在 LingXi 搜索中输入 "截图"，出现截图选项
- 设置页显示所有截图相关设置项
- 修改设置后行为正确（如改为截图后自动保存）

---

## 实现优先级总览

```
Phase 1（基础截图）→ Phase 2（标注编辑器）→ Phase 3（导出与集成）
      ↓                      ↓                       ↓
   MVP 可用             核心完整               深度集成
```

共 **20 个步骤**，每步可独立验证：

| 阶段 | 步骤数 | 关键里程碑 |
|------|--------|-----------|
| Phase 1 | 7 步 (1.1 ~ 1.7) | 1.5 完成后即可端到端截图 |
| Phase 2 | 9 步 (2.1 ~ 2.9) | 2.4 完成后即可基本标注 |
| Phase 3 | 4 步 (3.1 ~ 3.4) | 3.1 完成后标注可导出 |
