//
//  AnnotationCanvasView.swift
//  LingXi
//

import AppKit
import SwiftUI

struct AnnotationCanvasView: NSViewRepresentable {
    var state: AnnotationState

    func makeNSView(context: Context) -> AnnotationCanvasNSView {
        DebugLog.log("[Memory] AnnotationCanvasView.makeNSView")
        let view = AnnotationCanvasNSView(state: state)
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasNSView, context: Context) {
        nsView.state = state
        nsView.needsDisplay = true
    }

    static func dismantleNSView(_ nsView: AnnotationCanvasNSView, coordinator: ()) {
        DebugLog.log("[Memory] AnnotationCanvasView.dismantleNSView")
    }
}

// MARK: - NSView subclass

final class AnnotationCanvasNSView: NSView {
    var state: AnnotationState

    init(state: AnnotationState) {
        DebugLog.log("[Memory] AnnotationCanvasNSView.init")
        self.state = state
        super.init(frame: .zero)
        startObservation()
        state.onCancelTextEditing = { [weak self] in
            self?.cancelTextEditing()
        }
    }

    private func cancelTextEditing() {
        guard let textField = activeTextField else { return }
        textField.removeFromSuperview()
        activeTextField = nil
        textInsertionPoint = nil
        editingAnnotationId = nil
        editingAnnotationProperties = nil
    }

    deinit {
        DebugLog.log("[Memory] AnnotationCanvasNSView.deinit")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static let minimumPointDistance: CGFloat = 2.0
    private static let defaultFontName = "Helvetica"
    private static let handleSize: CGFloat = 8.0
    private static let handleHitRadius: CGFloat = 10.0

    private var activeTextField: NSTextField?
    private var textInsertionPoint: CGPoint?
    private var editingAnnotationId: UUID?
    private var editingAnnotationProperties: AnnotationProperties?
    private var blurCacheManager: BlurCacheManager { state.blurCacheManager }
    private var cachedSourceCGImage: CGImage?
    private var cachedSourceImageId: ObjectIdentifier?

    // MARK: - Selection drag state

    private enum DragMode {
        case move
        case resizeHandle(HandlePosition)
    }

    private enum HandlePosition {
        case topLeft, topRight, bottomLeft, bottomRight
        case start, end
    }

    private struct DragState {
        let mode: DragMode
        let startPoint: CGPoint
        let originalItem: AnnotationItem
        let index: Int
    }

    private var activeDrag: DragState?

    private func startObservation() {
        withObservationTracking {
            _ = self.state.annotations
            _ = self.state.isDrawing
            _ = self.state.drawingStartPoint
            _ = self.state.drawingEndPoint
            _ = self.state.currentPoints
            _ = self.state.selectedTool
            _ = self.state.sourceImage
            _ = self.state.selectedAnnotationId
            _ = self.state.strokeColor
            _ = self.state.fillColor
            _ = self.state.strokeWidth
            _ = self.state.fontSize
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.needsDisplay = true
                self?.startObservation()
            }
        }
    }

    // MARK: - Coordinate conversion

    private var displayScale: CGFloat {
        let imageSize = state.sourceImage.size
        guard imageSize.width > 0, imageSize.height > 0 else { return 1.0 }
        return min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    }

    private var imageOrigin: CGPoint {
        let imageSize = state.sourceImage.size
        let scale = displayScale
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        return CGPoint(
            x: (bounds.width - scaledWidth) / 2,
            y: (bounds.height - scaledHeight) / 2
        )
    }

    func imageToDisplay(_ point: CGPoint) -> CGPoint {
        let scale = displayScale
        let origin = imageOrigin
        return CGPoint(x: point.x * scale + origin.x, y: point.y * scale + origin.y)
    }

    func displayToImage(_ point: CGPoint) -> CGPoint {
        let scale = displayScale
        let origin = imageOrigin
        guard scale > 0 else { return .zero }
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cgContext = NSGraphicsContext.current?.cgContext else { return }

        cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
        cgContext.fill(bounds)

        let scale = displayScale
        let origin = imageOrigin

        cgContext.saveGState()
        cgContext.translateBy(x: origin.x, y: origin.y)
        cgContext.scaleBy(x: scale, y: scale)

        let cgImage = resolvedSourceCGImage()
        drawSourceImage(cgImage, in: cgContext)

        let renderer = AnnotationRenderer(
            context: cgContext,
            sourceImage: cgImage,
            blurCacheManager: blurCacheManager
        )
        drawAnnotations(renderer)
        drawCurrentStroke(renderer)
        drawSelectionHighlight(in: cgContext)

        cgContext.restoreGState()
    }

    private func drawSourceImage(_ cgImage: CGImage?, in context: CGContext) {
        guard let cgImage else { return }
        let imageSize = state.sourceImage.size
        context.saveGState()
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
    }

    private func resolvedSourceCGImage() -> CGImage? {
        let id = ObjectIdentifier(state.sourceImage)
        if cachedSourceImageId != id {
            cachedSourceCGImage = state.sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            cachedSourceImageId = id
            blurCacheManager.clearCache()
        }
        return cachedSourceCGImage
    }

    private func drawAnnotations(_ renderer: AnnotationRenderer) {
        renderer.render(state.annotations)
    }

    private func drawCurrentStroke(_ renderer: AnnotationRenderer) {
        guard state.isDrawing else { return }

        let properties = currentProperties()

        if state.selectedTool.isPathBased {
            if let previewItem = AnnotationFactory.makePathAnnotation(
                tool: state.selectedTool,
                points: state.currentPoints,
                properties: properties
            ) {
                renderer.render([previewItem])
            }
        } else if let start = state.drawingStartPoint,
                  let end = state.drawingEndPoint {
            let rect = AnnotationFactory.normalizedRect(from: start, to: end)

            if state.selectedTool == .crop {
                renderer.renderCropOverlay(rect: rect, imageSize: state.sourceImage.size)
            } else if let previewItem = AnnotationFactory.makeAnnotation(
                tool: state.selectedTool,
                from: start,
                to: end,
                properties: properties
            ) {
                renderer.render([previewItem])
            }
        }
    }

    private func currentProperties() -> AnnotationProperties {
        AnnotationProperties(
            strokeColor: state.strokeColor,
            fillColor: state.fillColor,
            strokeWidth: state.strokeWidth,
            fontSize: state.fontSize,
            fontName: Self.defaultFontName,
            blurType: state.blurType
        )
    }

    // MARK: - Selection hit test

    private func hitTestHandle(at point: CGPoint, for annotation: AnnotationItem) -> HandlePosition? {
        let radius = Self.handleHitRadius
        let handles = handlePositions(for: annotation)
        for (position, center) in handles {
            if hypot(point.x - center.x, point.y - center.y) <= radius {
                return position
            }
        }
        return nil
    }

    private func handlePositions(for annotation: AnnotationItem) -> [(HandlePosition, CGPoint)] {
        switch annotation.type {
        case .arrow(let s, let e), .line(let s, let e):
            return [(.start, s), (.end, e)]
        case .path, .highlight:
            // Path-based annotations don't support resize — only move
            return []
        default:
            let r = annotation.bounds
            return [
                (.topLeft, CGPoint(x: r.minX, y: r.minY)),
                (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
                (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
            ]
        }
    }

    private func selectAnnotation(at point: CGPoint) {
        // First check handles of already-selected annotation
        if let selected = state.selectedAnnotation,
           let handle = hitTestHandle(at: point, for: selected) {
            beginDrag(mode: .resizeHandle(handle), at: point, item: selected)
            return
        }

        // Hit test body — reverse order for topmost first
        for annotation in state.annotations.reversed() {
            let hitRect = annotation.bounds.insetBy(dx: -Self.handleHitRadius, dy: -Self.handleHitRadius)
            if hitRect.contains(point) {
                state.selectedAnnotationId = annotation.id
                // Check if clicking on a handle of the newly selected item
                if let handle = hitTestHandle(at: point, for: annotation) {
                    beginDrag(mode: .resizeHandle(handle), at: point, item: annotation)
                } else {
                    beginDrag(mode: .move, at: point, item: annotation)
                }
                return
            }
        }
        state.selectedAnnotationId = nil
    }

    // MARK: - Drag

    private func beginDrag(mode: DragMode, at point: CGPoint, item: AnnotationItem) {
        guard let index = state.annotations.firstIndex(where: { $0.id == item.id }) else { return }
        activeDrag = DragState(mode: mode, startPoint: point, originalItem: item, index: index)
        state.beginDrag()
    }

    private func handleDrag(to point: CGPoint) {
        guard let drag = activeDrag else { return }

        let delta = CGSize(width: point.x - drag.startPoint.x, height: point.y - drag.startPoint.y)

        switch drag.mode {
        case .move:
            let moved = drag.originalItem.translated(by: delta)
            state.updateDragging(at: drag.index) { $0 = moved }

        case .resizeHandle(let handle):
            let resized = resizeAnnotation(drag.originalItem, handle: handle, to: point)
            state.updateDragging(at: drag.index) { $0 = resized }
        }
    }

    private func endDrag() {
        activeDrag = nil
    }

    private func resizeAnnotation(_ item: AnnotationItem, handle: HandlePosition, to point: CGPoint) -> AnnotationItem {
        switch item.type {
        case .arrow(let s, let e), .line(let s, let e):
            let newStart = handle == .start ? point : s
            let newEnd = handle == .end ? point : e
            let bounds = AnnotationFactory.normalizedRect(from: newStart, to: newEnd)
            let newType: AnnotationType = item.type.isArrow
                ? .arrow(start: newStart, end: newEnd)
                : .line(start: newStart, end: newEnd)
            return AnnotationItem(id: item.id, type: newType, bounds: bounds, properties: item.properties)

        default:
            let anchor = anchorPoint(for: item.bounds, opposite: handle)
            let newRect = AnnotationFactory.normalizedRect(from: anchor, to: point)
            let newType = resizedType(item.type, to: newRect)
            return AnnotationItem(id: item.id, type: newType, bounds: newRect, properties: item.properties)
        }
    }

    private func anchorPoint(for rect: CGRect, opposite handle: HandlePosition) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.minY)
        case .start, .end: CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    private func resizedType(_ type: AnnotationType, to rect: CGRect) -> AnnotationType {
        switch type {
        case .rectangle: .rectangle(rect)
        case .filledRectangle: .filledRectangle(rect)
        case .ellipse: .ellipse(rect)
        case .blur(let blurType): .blur(blurType)
        case .text(let text): .text(text)
        case .counter(let n): .counter(n)
        default: type
        }
    }

    // MARK: - Selection highlight

    private func drawSelectionHighlight(in context: CGContext) {
        guard let annotation = state.selectedAnnotation else { return }

        let hs = Self.handleSize

        // Dashed border
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.0)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.stroke(annotation.bounds)
        context.setLineDash(phase: 0, lengths: [])

        // Handles
        context.setFillColor(NSColor.white.cgColor)
        let handles = handlePositions(for: annotation)
        for (_, center) in handles {
            let handleRect = CGRect(x: center.x - hs / 2, y: center.y - hs / 2, width: hs, height: hs)
            context.fillEllipse(in: handleRect)
            context.strokeEllipse(in: handleRect)
        }
    }

    // MARK: - Text field editing

    private func showTextField(at viewPoint: CGPoint, imagePoint: CGPoint, existingText: String = "") {
        textInsertionPoint = imagePoint

        let scale = displayScale
        let fontSize = state.fontSize * scale

        let textField = NSTextField()
        textField.isEditable = true
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        let properties = currentProperties()
        textField.font = NSFont(name: properties.fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        textField.textColor = NSColor(state.strokeColor)
        textField.stringValue = existingText
        textField.placeholderString = "Type here"
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.sizeToFit()
        textField.frame = NSRect(
            x: viewPoint.x,
            y: viewPoint.y,
            width: max(100 * scale, bounds.width - viewPoint.x - 8),
            height: fontSize + 8
        )
        textField.target = self
        textField.action = #selector(textFieldAction(_:))

        addSubview(textField)
        window?.makeFirstResponder(textField)
        activeTextField = textField
    }

    @objc private func textFieldAction(_ sender: NSTextField) {
        commitActiveTextField()
    }

    private func commitActiveTextField() {
        guard let textField = activeTextField,
              let imagePoint = textInsertionPoint else { return }

        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        textField.removeFromSuperview()
        activeTextField = nil
        textInsertionPoint = nil

        guard !text.isEmpty else {
            // If editing existing and cleared text, delete annotation
            if let editId = editingAnnotationId {
                state.deleteAnnotation(id: editId)
                editingAnnotationId = nil
            }
            return
        }

        if let editId = editingAnnotationId {
            let properties = editingAnnotationProperties ?? currentProperties()
            let size = (text as NSString).size(withAttributes: properties.textAttributes())
            state.updateAnnotation(id: editId) { item in
                item.type = .text(text)
                item.bounds = CGRect(origin: imagePoint, size: size)
            }
            editingAnnotationId = nil
            editingAnnotationProperties = nil
        } else {
            let properties = currentProperties()
            let item = AnnotationFactory.makeTextAnnotation(
                at: imagePoint,
                text: text,
                properties: properties
            )
            state.addAnnotation(item)
        }
    }

    private func beginEditingTextAnnotation(_ annotation: AnnotationItem) {
        guard case .text(let text) = annotation.type else { return }
        editingAnnotationId = annotation.id
        editingAnnotationProperties = annotation.properties
        let viewPoint = imageToDisplay(annotation.bounds.origin)
        showTextField(at: viewPoint, imagePoint: annotation.bounds.origin, existingText: text)
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = displayToImage(viewPoint)

        switch state.selectedTool {
        case .selection:
            commitActiveTextField()
            // Double-click on text annotation → edit
            if event.clickCount == 2 {
                for annotation in state.annotations.reversed() {
                    if annotation.bounds.contains(imagePoint), case .text = annotation.type {
                        state.selectedAnnotationId = annotation.id
                        beginEditingTextAnnotation(annotation)
                        return
                    }
                }
            }
            selectAnnotation(at: imagePoint)
            return
        case .text:
            commitActiveTextField()
            showTextField(at: viewPoint, imagePoint: imagePoint)
            return
        case .counter:
            commitActiveTextField()
            let properties = currentProperties()
            let item = AnnotationFactory.makeCounterAnnotation(
                at: imagePoint,
                number: state.nextCounterNumber,
                properties: properties
            )
            state.addAnnotation(item)
            return
        default:
            break
        }

        guard supportedDrawingTool else { return }

        state.isDrawing = true

        if state.selectedTool.isPathBased {
            state.currentPoints = [imagePoint]
        } else {
            state.drawingStartPoint = imagePoint
            state.drawingEndPoint = imagePoint
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = displayToImage(viewPoint)

        // Handle selection drag
        if state.selectedTool == .selection && activeDrag != nil {
            handleDrag(to: imagePoint)
            return
        }

        guard state.isDrawing else { return }

        if state.selectedTool.isPathBased {
            if let last = state.currentPoints.last,
               hypot(imagePoint.x - last.x, imagePoint.y - last.y) < Self.minimumPointDistance {
                return
            }
            state.currentPoints.append(imagePoint)
        } else {
            state.drawingEndPoint = imagePoint
        }
    }

    override func mouseUp(with event: NSEvent) {
        // End selection drag
        if state.selectedTool == .selection && activeDrag != nil {
            endDrag()
            return
        }

        guard state.isDrawing else { return }

        state.isDrawing = false
        let properties = currentProperties()

        if state.selectedTool.isPathBased {
            if let item = AnnotationFactory.makePathAnnotation(
                tool: state.selectedTool,
                points: state.currentPoints,
                properties: properties
            ) {
                state.addAnnotation(item)
            }
            state.currentPoints.removeAll()
        } else {
            guard let start = state.drawingStartPoint,
                  let end = state.drawingEndPoint else { return }

            let minDragDistance = Self.minimumPointDistance
            let distance = hypot(end.x - start.x, end.y - start.y)
            guard distance >= minDragDistance else {
                state.drawingStartPoint = nil
                state.drawingEndPoint = nil
                return
            }

            if state.selectedTool == .crop {
                let rect = AnnotationFactory.normalizedRect(from: start, to: end)
                state.applyCrop(rect: rect)
            } else if let item = AnnotationFactory.makeAnnotation(
                tool: state.selectedTool,
                from: start,
                to: end,
                properties: properties
            ) {
                state.addAnnotation(item)
            }

            state.drawingStartPoint = nil
            state.drawingEndPoint = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{1B}", activeTextField != nil {
            cancelTextEditing()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        guard state.selectedTool == .selection,
              let annotation = state.selectedAnnotation else { return }

        let scale = displayScale
        let origin = imageOrigin
        let handles = handlePositions(for: annotation)

        for (_, center) in handles {
            let viewPoint = CGPoint(x: center.x * scale + origin.x, y: center.y * scale + origin.y)
            let cursorRect = CGRect(
                x: viewPoint.x - Self.handleHitRadius,
                y: viewPoint.y - Self.handleHitRadius,
                width: Self.handleHitRadius * 2,
                height: Self.handleHitRadius * 2
            )
            addCursorRect(cursorRect, cursor: .crosshair)
        }
    }

    private var supportedDrawingTool: Bool {
        switch state.selectedTool {
        case .rectangle, .filledRectangle, .ellipse, .line, .arrow, .pencil, .highlighter,
             .blur, .crop:
            true
        default:
            false
        }
    }
}
