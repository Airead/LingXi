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

    private var activeTextField: NSTextField?
    private var textInsertionPoint: CGPoint?
    private let blurCacheManager = BlurCacheManager()
    private var cachedSourceCGImage: CGImage?
    private var cachedSourceImageId: ObjectIdentifier?

    private func startObservation() {
        withObservationTracking {
            _ = self.state.annotations
            _ = self.state.isDrawing
            _ = self.state.drawingStartPoint
            _ = self.state.drawingEndPoint
            _ = self.state.currentPoints
            _ = self.state.selectedTool
            _ = self.state.sourceImage
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

    // MARK: - Text field editing

    private func showTextField(at viewPoint: CGPoint, imagePoint: CGPoint) {
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

        guard !text.isEmpty else { return }

        let properties = currentProperties()
        let item = AnnotationFactory.makeTextAnnotation(
            at: imagePoint,
            text: text,
            properties: properties
        )
        state.addAnnotation(item)
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = displayToImage(viewPoint)

        switch state.selectedTool {
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
        guard state.isDrawing else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = displayToImage(viewPoint)

        if state.selectedTool.isPathBased {
            // Skip points too close to the last one to limit array growth
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
            activeTextField?.removeFromSuperview()
            activeTextField = nil
            textInsertionPoint = nil
            return
        }
        super.keyDown(with: event)
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
