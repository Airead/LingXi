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
