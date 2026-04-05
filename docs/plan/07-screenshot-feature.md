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
