# 截图功能设计方案

> 参考项目：[Snapzy](https://github.com/duongductrong/Snapzy)（BSD-3 许可证）

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

### Phase 1：基础截图能力

**目标**：实现最基本的全屏截图和区域截图，截图结果保存到剪贴板。

#### 1.1 ScreenCaptureService — 屏幕捕获封装

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

预取优化：
- 在用户选择区域时提前调用 `SCShareableContent.current` 加载可用内容
- 选择完成后可立即执行截图，无需等待

#### 1.2 RegionSelectionController — 区域选择协调器

核心职责：
- 管理区域选择窗口池（每个屏幕一个窗口）
- 协调选择流程的生命周期
- 处理 Escape 键取消

```swift
@MainActor
class RegionSelectionController {
    static let shared = RegionSelectionController()

    /// Pre-allocated window pool (one per screen)
    private var windowPool: [NSScreen: RegionSelectionWindow] = [:]

    /// Start region selection, returns selected region in screen coordinates
    func startSelection() async -> (region: CGRect, screen: NSScreen)?

    /// Cancel current selection
    func cancelSelection()
}
```

**窗口池优化**（参考 Snapzy 核心优化）：
- 应用启动时为每个屏幕预分配 `RegionSelectionWindow`
- 使用 `orderOut` / `orderFrontRegardless` 隐藏/显示，而非创建/销毁
- 监听 `NSApplication.didChangeScreenParametersNotification` 动态刷新窗口池
- 目标：选区窗口激活时间 < 150ms

#### 1.3 RegionSelectionWindow — 全屏覆盖面板

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

#### 1.4 RegionSelectionOverlayView — 选区绘制与交互

核心职责：
- 处理鼠标事件（拖拽选区）
- CALayer 渲染（遮罩 + 选框 + 十字准星）

**CALayer 层结构**：
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

**坐标转换**：
- View 坐标 → Window 坐标 → 全局屏幕坐标
- Cocoa 坐标系（左下原点）与屏幕坐标系转换
- 考虑多显示器布局和 Retina 缩放

#### 1.5 ScreenshotManager — 截图流程协调

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
    → 复制到剪贴板 / 进入标注编辑器
```

> 覆盖窗口使用截图做背景而非实时透视，避免桌面内容变化导致的视觉跳动，也是主流截图工具的通用做法。

#### 1.6 快捷键集成

在现有的 `HotKeyManager` 中注册截图快捷键：
- 区域截图：默认 `⌘⇧4`（可自定义，避免与系统冲突）
- 全屏截图：默认 `⌘⇧3`（可自定义）

在 `AppSettings` 中添加截图相关设置项。

#### 1.7 测试计划

| 测试文件 | 覆盖内容 |
|----------|----------|
| `ScreenCaptureServiceTests.swift` | 权限检查逻辑、图片裁剪（含 Retina 缩放）、坐标转换 |
| `RegionSelectionControllerTests.swift` | 窗口池管理、多显示器场景、选区最小尺寸验证 |
| `ScreenshotManagerTests.swift` | 截图流程协调、面板隐藏/恢复、剪贴板写入 |

---

### Phase 2：标注编辑器

**目标**：截图完成后进入标注编辑窗口，支持常用标注工具。

#### 2.1 标注数据模型

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

#### 2.2 工具类型

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

#### 2.3 AnnotationState — 标注编辑器状态

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

#### 2.4 AnnotationCanvasView — 绘制画布

使用 `NSViewRepresentable` 包裹 `NSView` 子类，实现高性能绘制：

**核心设计原则**：
- 所有标注坐标存储为**图像坐标系**（与显示缩放无关）
- 渲染时通过 `displayScale` 将图像坐标映射到视图坐标
- `displayToImage()` / `imageToDisplay()` 进行坐标转换

**鼠标事件状态机**：

| 当前工具 | mouseDown | mouseDragged | mouseUp |
|----------|-----------|--------------|---------|
| selection | 命中测试 → 选中/开始拖动 | 移动标注/调整大小 | 确认位置 |
| rectangle/ellipse | 记录起点 | 实时预览矩形 | 创建标注 |
| arrow/line | 记录起点 | 实时预览线段 | 创建标注 |
| pencil/highlighter | 记录起点 | 收集路径点 | 创建路径标注 |
| text | 在点击位置创建文本框 | — | — |
| blur | 记录起点 | 实时预览模糊区域 | 创建模糊标注 |
| counter | 在点击位置创建计数器 | — | — |
| crop | 记录起点 | 实时预览裁剪区域 | 应用裁剪 |

**`draw(_:)` 渲染流程**：
1. 应用缩放变换 (`displayScale`)
2. 绘制源图像
3. 创建 `AnnotationRenderer`，遍历所有标注进行渲染
4. 绘制选中标注的调整手柄（8 个方向）
5. 绘制当前正在进行的笔划（实时预览）

#### 2.5 AnnotationRenderer — 标注渲染器

纯 `CGContext` 渲染，每种标注类型有专门的绘制方法：

- **矩形/椭圆**：`CGContext.stroke/fill` + `CGPath`
- **箭头**：线段 + 三角函数计算箭头尖端三角形
- **自由画笔**：`CGPath.addLines` 连接所有采样点
- **高亮笔**：同画笔，但使用半透明颜色 + 较宽线宽
- **文字**：`NSAttributedString.draw(at:)` 或 `CTLineDraw`
- **模糊/马赛克**：`CIPixellate` 或 `CIGaussianBlur` 处理选区图像
- **计数器**：绘制带编号的圆形标记

#### 2.6 AnnotationHitTester — 命中测试

用于 selection 工具的点击判定：

- **矩形**：`bounds.contains(point)` 或边框 ±tolerance 命中
- **椭圆**：椭圆方程 `(x/a)² + (y/b)² ≤ 1`
- **箭头/线段**：点到线段距离 < tolerance
- **路径**：点到折线最近距离 < tolerance
- **文字**：bounds 包含
- **计数器**：圆形半径内

选中标注显示 8 个调整手柄，命中手柄时进入 resize 模式。

#### 2.7 BlurCacheManager — 模糊效果缓存

模糊是计算密集型操作，需要缓存优化：

- 首次模糊区域时计算并缓存结果
- 交互式拖动时，如果区域变化小于阈值，复用之前的缓存（近似复用）
- 区域确认后重新计算精确模糊
- 缓存 key：区域 rect + 模糊类型 + 模糊参数

#### 2.8 AnnotationFactory — 标注创建工厂

```swift
struct AnnotationFactory {
    /// Create annotation from drawing gesture
    static func createAnnotation(
        tool: AnnotationTool,
        startPoint: CGPoint,
        endPoint: CGPoint,
        path: [CGPoint],
        state: AnnotationState
    ) -> AnnotationItem?
}
```

根据当前工具类型和手势数据创建对应的 `AnnotationItem`。text / selection / crop 类型不通过工厂创建。

#### 2.9 标注编辑窗口

**AnnotationWindow** (NSWindow 子类)：
- 自定义标题栏（透明，与编辑器融为一体）
- 覆写 `performKeyEquivalent` 处理快捷键：
  - `⌘S`：保存
  - `⌘⇧S`：另存为
  - `⌘Z`：撤销
  - `⌘⇧Z`：重做
  - `⌘C`：复制到剪贴板
  - `Delete`：删除选中标注
  - 数字键 / 字母键：切换工具
- 覆写 `sendEvent` 处理：
  - `⌘+滚轮`：缩放
  - 触控板捏合：缩放
  - `Space+拖动`：平移画布

**AnnotationEditorView** (SwiftUI 主视图)：
```
┌──────────────────────────────────────┐
│  Toolbar (tools, color, stroke...)   │
├──────────────────────────────────────┤
│                                      │
│         AnnotationCanvasView         │
│        (NSViewRepresentable)         │
│                                      │
├──────────────────────────────────────┤
│  Bottom bar (zoom, save, copy...)    │
└──────────────────────────────────────┘
```

#### 2.10 测试计划

| 测试文件 | 覆盖内容 |
|----------|----------|
| `AnnotationItemTests.swift` | 模型创建、相等性、属性修改 |
| `AnnotationStateTests.swift` | 状态管理、Undo/Redo、工具切换、标注增删 |
| `AnnotationFactoryTests.swift` | 各工具类型的标注创建 |
| `AnnotationHitTesterTests.swift` | 各形状的命中测试、边界情况 |
| `AnnotationRendererTests.swift` | 渲染输出验证（可用快照测试） |
| `ImageExporterTests.swift` | 合成输出、格式转换 |

---

### Phase 3：导出与集成

**目标**：完善导出功能，与 LingXi 搜索系统集成。

#### 3.1 ImageExporter — 图片导出

```swift
struct ImageExporter {
    /// Render final image with all annotations
    static func renderFinalImage(source: CGImage, annotations: [AnnotationItem]) -> NSImage

    /// Save to file (PNG/JPEG)
    static func saveToFile(_ image: NSImage, path: URL, format: ImageFormat) throws

    /// Copy to clipboard
    static func copyToClipboard(_ image: NSImage)
}
```

渲染流程：
1. 在图像坐标系创建 `CGContext`（原生分辨率）
2. 绘制源图
3. 使用 `AnnotationRenderer` 遍历渲染所有标注
4. 输出 `NSImage`

支持格式：PNG（默认，保留透明度）、JPEG（可配置质量）。

#### 3.2 与 LingXi 集成

- 在 LingXi 搜索中注册 "screenshot" 系统命令（类似 F07 系统命令源）
- 用户输入 "截图" / "screenshot" 时显示截图选项
- 截图历史可作为未来的搜索数据源

#### 3.3 设置项

在 `AppSettings` 和 `SettingsView` 中添加：

| 设置项 | 说明 | 默认值 |
|--------|------|--------|
| 截图快捷键 | 区域截图 / 全屏截图 | `⌘⇧4` / `⌘⇧3` |
| 截图后行为 | 复制到剪贴板 / 打开标注编辑器 / 保存到文件 | 复制到剪贴板 |
| 默认保存路径 | 截图文件保存目录 | ~/Desktop |
| 默认图片格式 | PNG / JPEG | PNG |
| JPEG 质量 | 0-100 | 90 |

---

## 实现优先级

```
Phase 1（基础截图）→ Phase 2（标注编辑器）→ Phase 3（导出与集成）
      ↓                      ↓                       ↓
   MVP 可用             核心完整               深度集成
```

**Phase 1 内部实现顺序**：
1. `ScreenCaptureService`（权限 + 截图）
2. `RegionSelectionWindow` + `RegionSelectionOverlayView`（选区 UI）
3. `RegionSelectionController`（窗口池 + 协调）
4. `ScreenshotManager`（流程串联）
5. 快捷键注册 + 设置项
6. 测试

**Phase 2 内部实现顺序**：
1. `AnnotationItem` + `AnnotationTool`（数据模型）
2. `AnnotationState`（状态管理 + Undo/Redo）
3. `AnnotationCanvasView`（画布绘制 + 鼠标交互）
4. `AnnotationRenderer`（CGContext 渲染）
5. `AnnotationHitTester`（选中 + 调整）
6. `AnnotationFactory`（标注创建）
7. `AnnotationToolbar` + `AnnotationEditorView`（UI 布局）
8. `AnnotationWindow`（窗口管理 + 快捷键）
9. `BlurCacheManager`（模糊优化）
10. 测试

## Snapzy 架构参考

> 以下是对 Snapzy 项目架构的详细分析，作为本方案的设计参考。

### 项目概览

Snapzy 是一个原生 macOS 截图/录屏/标注应用，使用 SwiftUI + AppKit 混合架构，基于 ScreenCaptureKit 实现屏幕捕获。项目采用特性驱动的扁平化结构组织代码。

技术栈：SwiftUI, AppKit, ScreenCaptureKit, Vision (OCR), CoreGraphics, CALayer

### 目录结构

```
Snapzy/
  App/
    SnapzyApp.swift              // @main entry point
    AppCoordinator.swift         // Lifecycle coordinator
    AppEnvironment.swift         // DI container (minimal)
    AppStatusBarController.swift // Menu bar control

  Features/
    Capture/
      CaptureViewModel.swift     // Screenshot/recording main ViewModel
    Annotate/
      AnnotateMainView.swift     // Annotation editor main view
      AnnotateManager.swift      // Annotation window manager (singleton)
      AnnotateState.swift        // Core editor state (~800 lines)
      Components/                // Sub-views (Canvas, Toolbar, Sidebar...)
      Managers/                  // AnnotateWindow, WindowController
      Models/                    // AnnotationItem, ToolType, MockupPreset...
      Services/                  // Renderer, Factory, Exporter, BlurCache...
    Recording/                   // Screen recording
    VideoEditor/                 // Video editor
    QuickAccess/                 // Post-capture floating window
    Preferences/                 // Settings panel
    Onboarding/                  // First-run guide

  Services/
    Capture/
      ScreenCaptureManager.swift     // ScreenCaptureKit wrapper (core)
      AreaSelectionWindow.swift      // Region selection overlay
      ScreenRecordingManager.swift   // Recording manager
      ...
    Clipboard/, Cloud/, Media/, Shortcuts/, ...

  Shared/
    Components/     // Reusable UI components
    Extensions/     // NSWindow extensions etc.
    Styles/         // Design tokens
```

### 屏幕捕获 (ScreenCaptureManager)

核心设计：
- **单例 + @MainActor**：`ScreenCaptureManager.shared`，线程安全
- **权限管理三段式**：
  1. `CGPreflightScreenCaptureAccess()` 快速路径
  2. `SCShareableContent.current` 触发系统弹窗（macOS 13-14）
  3. `CGRequestScreenCaptureAccess()` 打开系统设置（macOS 15+）
- **macOS 兼容**：macOS 14+ 使用 `SCScreenshotManager.captureImage()`，macOS 13 回退到 `SCStream` 单帧捕获
- **预取优化**：用户选择区域时提前加载 `SCShareableContent`，选择完成后立即截图
- **区域捕获策略**：先全屏捕获原生分辨率 → `CGImage.cropping(to:)` 像素级裁剪（避免 `sourceRect` 插值模糊）
- **坐标转换**：Cocoa 坐标（左下原点）与屏幕坐标间的转换，包含 Retina `backingScaleFactor` 处理
- **多格式输出**：PNG / JPEG / WebP

数据流：
```
用户触发 → CaptureViewModel → AreaSelectionController (区域选择)
                             → ScreenCaptureManager (执行截图)
                             → PostCaptureActionHandler (后续动作)
                             → QuickAccessManager (浮窗展示)
```

### 区域选择 (AreaSelectionWindow)

**三层结构**：
1. **`AreaSelectionController`**（单例协调器）：管理窗口池、生命周期、Escape 键监听
2. **`AreaSelectionWindow`**（NSPanel 子类）：每个屏幕一个，全屏无边框叠加面板
3. **`AreaSelectionOverlayView`**（NSView 子类）：处理鼠标事件和 CALayer 渲染

**窗口池优化（核心亮点）**：
- 应用启动时为每个屏幕预分配 `AreaSelectionWindow`，实现 <150ms 激活（vs 400-600ms 即时创建）
- 窗口使用 `orderOut` / `orderFrontRegardless` 隐藏/显示，而非创建/销毁
- 监听 `NSApplication.didChangeScreenParametersNotification` 动态刷新窗口池
- `pooled: true` 模式：窗口创建后立即隐藏

**NSPanel 配置**：
```swift
styleMask: [.borderless, .nonactivatingPanel]  // Don't steal focus
level: .screenSaver                              // Highest level
canBecomeKey: false
canBecomeMain: false
collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]
animationBehavior: .none
```

**CALayer 渲染（60fps）**：
- `dimLayer`：全屏半透明黑色遮罩
- `selectionBorderLayer`：选区边框
- `crosshairIndicatorLayer`：十字准星指示器（带阴影）
- 使用 `CATransaction.setDisableActions(true)` 禁用隐式动画
- 选区透明效果通过 `CAShapeLayer` mask + `evenOdd` 填充规则实现

**鼠标事件**：
- `mouseDown`：记录起点，开始选择
- `mouseDragged`：更新选区，layer 实时渲染
- `mouseUp`：选区 > 5×5 px 确认，否则重置
- `mouseMoved`：更新十字准星位置
- `rightMouseDown`：取消选择

### 标注系统

#### 数据模型 (AnnotationItem)

```swift
// Snapzy's annotation type enum
enum AnnotationType {
    case path([CGPoint])           // Free-hand
    case rectangle, filledRectangle, oval  // Shapes
    case arrow(start:end:), line(start:end:)  // Lines
    case text(String)              // Text
    case highlight([CGPoint])      // Highlighter
    case blur(BlurType)            // Pixelate/Gaussian
    case counter(Int)              // Step number
}

struct AnnotationProperties {
    var strokeColor: Color
    var fillColor: Color
    var strokeWidth: CGFloat
    var fontSize: CGFloat
    var fontName: String
}

struct AnnotationItem: Identifiable, Equatable {
    let id: UUID
    var type: AnnotationType
    var bounds: CGRect
    var properties: AnnotationProperties
}
```

#### 状态管理 (AnnotateState, ~800+ 行)

`@MainActor + ObservableObject`，管理：
- 图像状态：`sourceImage`, `cutoutImage`, `isCutoutApplied`
- 工具状态：`selectedTool`, `strokeWidth`, `strokeColor`, `fillColor`, `blurType`
- 编辑器模式：`.annotate` / `.mockup` / `.preview`
- 标注列表：`annotations: [AnnotationItem]`
- 选择状态：`selectedAnnotationId`, `editingTextAnnotationId`
- Undo/Redo：基于状态快照的 `saveState()`, `undo()`, `redo()`
- 裁剪：`cropRect`, `isCropActive`, `cropAspectRatio`
- 缩放/平移：`zoomLevel` (0.25-4.0), `panOffset`, `isSpacePanning`

#### 绘制画布 (DrawingCanvasNSView)

**NSViewRepresentable 包裹 NSView 子类**（非纯 SwiftUI），用于高性能绘制：
- 所有标注坐标存储为图像坐标系
- `displayScale` 渲染时映射到视图坐标
- `displayToImage()` / `imageToDisplay()` 坐标转换

鼠标事件处理：
- 双击文本标注进入编辑模式
- 命中已有标注时选中并开始拖动
- 否则开始新绘制

渲染流程 (`draw(_:)`)：
1. 应用缩放变换
2. 创建 `AnnotationRenderer`
3. 遍历所有标注调用 `renderer.draw(annotation)`
4. 绘制选中标注的调整手柄
5. 绘制当前正在进行的笔划

#### 渲染器 (AnnotationRenderer)

纯 `CGContext` 渲染：
- 矩形/椭圆/线段：CGPath + stroke/fill
- 箭头：三角函数计算尖端三角形
- 模糊：`BlurCacheManager` + `BlurEffectRenderer`，支持近似复用缓存
- 画笔路径平滑

#### 命中测试 (hitTestAnnotation)

遍历标注（从顶到底），使用各类型精确命中逻辑：
- 矩形：`bounds.contains`
- 椭圆：椭圆方程判定
- 线/箭头：点到线段距离
- 路径：点到折线距离
- 计数器：圆形半径内

### 窗口管理

**AnnotateManager**（单例）：
- `windowControllers: [UUID: AnnotateWindowController]` 跟踪所有窗口
- 打开窗口时切换到 `.regular` 激活策略（显示在 Dock 和 Cmd+Tab）
- 所有窗口关闭后切回 `.accessory` 模式（仅菜单栏）
- 会话缓存 `AnnotationSessionData`：保存原始图像 + 标注 + 画布效果，用于重新编辑

**AnnotateWindow** (NSWindow 子类)：
- 自定义标题栏透明、深色主题
- 覆写 `performKeyEquivalent` 处理 Cmd+S、Cmd+Z 等快捷键
- 覆写 `sendEvent` 拦截 Cmd+滚轮（缩放）、触控板捏合、Space+拖动（平移）

### 导出流程

`AnnotateExporter`：
- `renderFinalImage()`：图像坐标系创建 CGContext → 绘制源图 → 遍历渲染所有标注 → 返回 NSImage
- 支持 Save / Save As / Copy+Close 三种导出方式
- JPEG 无法存储透明度时自动告警

### 关键架构洞察

1. **AppKit + SwiftUI 混合**：性能关键路径使用 NSView / CALayer / CGContext；UI 布局使用 SwiftUI
2. **图像坐标系 vs 显示坐标系**：严格分离，标注存储为图像坐标，渲染时通过 `displayScale` 变换
3. **全屏捕获 + 后裁剪**：避免 `sourceRect` 插值模糊
4. **窗口池预分配**：选择窗口激活时间从 400-600ms 降到 <150ms
5. **NSPanel + nonactivatingPanel**：防止叠加层抢夺焦点
6. **Notification 解耦**：窗口级快捷键通过 NotificationCenter 传递到 SwiftUI 视图
7. **Blur 缓存**：交互拖动时使用近似复用避免重计算
8. **会话恢复**：标注编辑可关闭后重新打开，恢复完整编辑状态

---

## macshot 架构参考

> 以下是对 [macshot](https://github.com/sw33tLie/macshot)（GPL-3.0）项目的分析，作为未来功能扩展参考。
> 注意：GPL-3.0 许可证有传染性，不能直接复制代码，仅供架构和思路参考。

### 项目概览

macshot 是功能最全面的开源 macOS 截图工具（CleanShot X 的开源替代品），使用纯 Swift + AppKit 构建，最低支持 macOS 12.3，空闲内存占用约 8 MB。支持 40 种语言国际化。

### 目录结构

```
macshot/
├── main.swift
├── AppDelegate.swift
├── Model/
│   └── Annotation.swift              # Core data model (~1945 lines)
├── Capture/
│   ├── ScreenCaptureManager.swift    # Screenshot core
│   ├── ScrollCaptureController.swift # Scrolling screenshot
│   ├── RecordingEngine.swift         # Screen recording engine
│   └── GIFEncoder.swift              # GIF encoder
├── Services/
│   ├── VisionOCR.swift               # OCR (Apple Vision)
│   ├── AutoRedactor.swift            # PII auto-redaction
│   ├── BeautifyRenderer.swift        # Beautify (window frame + gradient bg)
│   ├── ImageEffects.swift            # CIFilter adjustments
│   ├── ImageEncoder.swift            # Multi-format export (PNG/JPEG/HEIC/WebP)
│   ├── HotkeyManager.swift           # Global hotkeys
│   ├── ScreenshotHistory.swift       # History management
│   ├── TranslationService.swift      # Translation service
│   ├── BarcodeDetector.swift         # QR/barcode detection
│   └── SaveDirectoryAccess.swift     # Save path permissions
├── Upload/
│   ├── GoogleDriveUploader.swift     # Google Drive
│   ├── ImgbbUploader.swift           # imgbb
│   └── S3Uploader.swift              # S3 compatible (AWS/R2/MinIO)
├── UI/
│   ├── Overlay/                      # Screenshot overlay (main interaction)
│   │   ├── OverlayView.swift         # Core drawing view
│   │   ├── OverlayView+Popovers.swift
│   │   ├── OverlayView+WindowSnapping.swift
│   │   └── OverlayWindowController.swift
│   ├── Toolbar/
│   │   ├── ToolbarDefinitions.swift  # Toolbar button/layout definitions
│   │   ├── ToolbarStripView.swift
│   │   └── ToolOptionsRowView.swift  # Tool option row (style picker)
│   ├── Tools/                        # Annotation tools (one Handler per tool)
│   │   ├── AnnotationToolHandler.swift  # Protocol definition
│   │   ├── ArrowToolHandler.swift
│   │   ├── PencilToolHandler.swift
│   │   ├── MarkerToolHandler.swift
│   │   ├── LineToolHandler.swift
│   │   ├── RectangleToolHandler.swift
│   │   ├── FilledRectangleToolHandler.swift
│   │   ├── EllipseToolHandler.swift
│   │   ├── TextEditingController.swift
│   │   ├── NumberToolHandler.swift
│   │   ├── PixelateToolHandler.swift
│   │   ├── StampToolHandler.swift
│   │   ├── MeasureToolHandler.swift
│   │   └── LoupeToolHandler.swift
│   ├── Popover/                      # Popover panels
│   │   ├── ColorPickerView.swift
│   │   ├── EmojiPickerView.swift
│   │   ├── FontPickerView.swift
│   │   └── EffectsPickerView.swift
│   ├── Editor/                       # Standalone editor window
│   └── Windows/
│       ├── FloatingThumbnailController.swift
│       ├── HistoryOverlayController.swift
│       ├── OCRResultController.swift
│       ├── PinWindowController.swift
│       └── CountdownView.swift       # Delayed screenshot countdown
```

### 核心架构：AnnotationToolHandler Protocol

macshot 最值得借鉴的设计 — 工具逻辑完全解耦：

```swift
@MainActor protocol AnnotationToolHandler {
    var tool: AnnotationTool { get }
    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation?
    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas)
    func finish(canvas: AnnotationCanvas)
    var cursor: NSCursor? { get }
    func cursorForCanvas(_ canvas: AnnotationCanvas) -> NSCursor?
}
```

`AnnotationCanvas` protocol 解耦了工具与 OverlayView — 工具只通过 protocol 访问画布状态（颜色、线宽、标注列表、undo 栈等），不依赖具体视图类型。每个工具一个 Handler 类，便于独立开发和测试。

### 统一 Annotation 数据模型

所有标注类型共用一个 `Annotation` class（约 1945 行），属性集合是所有工具的超集：
- 基础：`startPoint`, `endPoint`, `color`, `strokeWidth`
- 形状：`rectFillStyle`, `rectCornerRadius`, `lineStyle`
- 箭头：`arrowStyle` (5 种), `arrowReversed`, `anchorPoints` (多锚点曲线)
- 文字：`attributedText`, `fontSize`, `isBold/Italic/Underline/Strikethrough`, `textBgColor`, `textOutlineColor`, `textAlignment`, `fontFamilyName`
- 编号：`number`, `numberFormat` (数字/罗马/字母)
- 审查：`censorMode` (像素化/模糊/实色/擦除), `bakedBlurNSImage`
- 图章：`stampImage`, `currentStampEmoji`
- 旋转：`rotation`（弧度值）

### Undo/Redo

使用 `UndoEntry` 枚举跟踪操作类型（added / removed / propertyChange 等），支持批量操作的 `groupID`。

### 箭头 5 种样式

`ArrowStyle` 枚举：
- `single` — 末端单箭头
- `thick` — 实心填充横幅箭头
- `double` — 两端箭头
- `open` — 开放/未填充 V 型箭头
- `tail` — 末端实心箭头 + 起点圆点

支持 `arrowReversed`（翻转方向）和右键添加锚点创建多段曲线。

### 滚动截图 (ScrollCaptureController)

最复杂的功能之一：
- 使用 `CGWindowListCreateImage` 按需抓帧（非流式）
- **帧对比**：TIFF 字节逐位比较，两帧完全相同 = 内容渲染完成
- **拼接**：使用 Apple Vision 的 `VNTranslationalImageRegistrationRequest` 精确计算像素偏移
- **增量合并**：新内容立即合入 `mergedImage`，不存储所有条带，内存受控
- **冻结表头检测**：自动识别固定表头，拼接时排除
- **滚动条排除**：自动检测滚动条宽度
- **自动滚动**：通过 `CGEventCreateScrollWheelEvent2` 编程式滚动
- 最大高度 30000 像素（可配置）
- 在专用串行 DispatchQueue 上进行捕获和比较

### 录屏 (RecordingEngine)

- `SCStream` 流式捕获
- MP4：`AVAssetWriter` + `AVAssetWriterInput`，H.264 最高 120fps
- GIF：自定义 `GIFEncoder`，5/10/15fps
- 系统音频：SCStream 内置支持，排除自身声音
- 麦克风：独立的 `AVCaptureSession`
- 鼠标点击高亮：`MouseHighlightOverlay` 涟漪效果

### OCR (VisionOCR)

极简实现 — Apple Vision 的薄包装：
- `VNRecognizeTextRequest`，`.accurate` 级别
- `usesLanguageCorrection = true`
- macOS 13+ 自动语言检测

### 自动打码 (AutoRedactor)

- 11 种 PII 模式：邮箱、电话、SSN、信用卡、CVV、IP 地址、AWS 密钥、Bearer Token 等
- 流程：OCR 识别文本 → 正则匹配 PII → 在对应位置创建审查标注

### 美化 (BeautifyRenderer)

- macOS 窗口框架模拟（红绿灯按钮 + 阴影）
- 30 种渐变样式，7 种 mesh gradient（macOS 15+）
- 可调参数：padding / cornerRadius / shadowRadius / bgRadius

### 云上传

**S3 上传器**最值得注意：
- 自实现 AWS Signature V4 签名，零外部依赖（仅用 CryptoKit）
- 兼容 AWS S3、Cloudflare R2、MinIO、DigitalOcean Spaces、Backblaze B2

### 工具栏设计

- 直接在 OverlayView 中绘制（非独立窗口），避免 z-order 问题
- 用户可启用/禁用每个工具
- 工具迁移机制：新版本添加的工具自动出现，已禁用的不会被重新启用

### 可借鉴功能优先级

| 功能 | 复杂度 | 价值 | 说明 |
|------|--------|------|------|
| **ToolHandler protocol 模式** | 低 | 高 | 解耦工具逻辑，易扩展 |
| **多种箭头样式** | 中 | 高 | 5 种 ArrowStyle + 多锚点曲线 |
| **富文本标注** | 中 | 高 | Bold/Italic/Underline + 背景色 + 描边 |
| **延迟截图** | 低 | 中 | 3/5/10/30 秒倒计时 |
| **像素测量尺** | 低 | 中 | px/pt 切换 |
| **取色器** | 低 | 中 | 点击取色 + hex 复制 |
| **自动打码 PII** | 中 | 中 | OCR + 正则匹配 |
| **美化/Beautify** | 中 | 中 | 窗口框 + 渐变背景 |
| **编号标记** | 低 | 中 | 自增编号，4 种格式 |
| **Emoji/图章** | 低 | 中 | 21 快速表情 + 分类选择器 |
| **OCR** | 低 | 中 | Apple Vision 薄包装 |
| **滚动截图** | 高 | 高 | Vision 拼接 + 冻结表头检测 |
| **录屏** | 高 | 高 | SCStream + GIF 编码 |
| **云上传** | 中 | 中 | S3 V4 签名零依赖 |

### 关键技术亮点

1. **AnnotationToolHandler protocol** — 工具逻辑与画布完全解耦，通过 `AnnotationCanvas` protocol 访问画布状态
2. **零外部依赖的 S3 上传** — 自己实现 AWS Sig V4，不引入 AWS SDK
3. **Vision 框架深度使用** — OCR + 滚动截图帧对齐 (`VNTranslationalImageRegistrationRequest`) + 人脸检测 + 背景移除
4. **增量拼接内存优化** — 滚动截图不存储所有帧，立即合并
5. **工具可配置性** — 用户可启用/禁用工具栏中每个工具，新版本工具自动出现
6. **直接在 OverlayView 绘制工具栏** — 避免多窗口 z-order 管理问题

---

## 架构关键决策

### 1. 全屏捕获 + 后裁剪（而非 sourceRect）

ScreenCaptureKit 的 `sourceRect` 会触发插值算法，导致截图边缘模糊。采用先全屏截图再 `CGImage.cropping(to:)` 裁剪的策略，确保像素级精确。

### 2. 截图做覆盖窗口背景（而非实时透视）

区域选择时，覆盖窗口背景使用预先捕获的全屏截图，而非让窗口透明实时显示桌面。避免桌面内容变化导致的视觉跳动，也是 Snipaste、iShot、Snapzy 等主流工具的做法。

### 3. AppKit + SwiftUI 混合（而非纯 SwiftUI）

性能关键路径（区域选择、标注画布）使用 NSView / CALayer / CGContext；UI 布局（工具栏、设置）使用 SwiftUI。这与 LingXi 现有的 Panel 模块风格一致。

### 4. 图像坐标系与显示坐标系分离

所有标注坐标存储为图像坐标系（与缩放无关），渲染时通过 `displayScale` 变换到视图坐标。确保缩放、导出时标注位置始终正确。

### 5. 窗口池预分配

应用启动时预分配区域选择窗口，使用 `orderOut` / `orderFrontRegardless` 控制显示。将选区窗口激活时间从 400-600ms 降到 <150ms。

### 6. 基于快照的 Undo/Redo

每次操作前保存 `[AnnotationItem]` 快照到 undo 栈。实现简单，对于标注数量不大的场景性能足够。如果未来标注数量极大，可改为 Command 模式。
