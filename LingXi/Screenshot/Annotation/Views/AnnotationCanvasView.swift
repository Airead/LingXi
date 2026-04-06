//
//  AnnotationCanvasView.swift
//  LingXi
//

import AppKit
import SwiftUI

struct AnnotationCanvasView: NSViewRepresentable {
    var state: AnnotationState

    func makeNSView(context: Context) -> AnnotationCanvasNSView {
        let view = AnnotationCanvasNSView(state: state)
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasNSView, context: Context) {
        nsView.state = state
        nsView.needsDisplay = true
    }
}

// MARK: - NSView subclass

final class AnnotationCanvasNSView: NSView {
    var state: AnnotationState

    init(state: AnnotationState) {
        self.state = state
        super.init(frame: .zero)
        startObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static let minimumPointDistance: CGFloat = 2.0

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
        } onChange: {
            DispatchQueue.main.async { [weak self] in
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

        drawSourceImage(in: cgContext)
        drawAnnotations(in: cgContext)
        drawCurrentStroke(in: cgContext)

        cgContext.restoreGState()
    }

    private func drawSourceImage(in context: CGContext) {
        guard let cgImage = state.sourceImage.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return }
        let imageSize = state.sourceImage.size
        // isFlipped = true, so y=0 is top. CGContext.draw expects origin at bottom-left,
        // so flip vertically within image space.
        context.saveGState()
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
    }

    private func drawAnnotations(in context: CGContext) {
        let renderer = AnnotationRenderer(context: context)
        renderer.render(state.annotations)
    }

    private func drawCurrentStroke(in context: CGContext) {
        guard state.isDrawing else { return }

        let properties = currentProperties()
        let renderer = AnnotationRenderer(context: context)

        if state.selectedTool.isPathBased {
            // Path-based preview (pencil / highlighter)
            if let previewItem = AnnotationFactory.makePathAnnotation(
                tool: state.selectedTool,
                points: state.currentPoints,
                properties: properties
            ) {
                renderer.render([previewItem])
            }
        } else if let start = state.drawingStartPoint,
                  let end = state.drawingEndPoint {
            // Two-point preview (rectangle, ellipse, line, arrow)
            if let previewItem = AnnotationFactory.makeAnnotation(
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
            fontSize: 14.0,
            fontName: "Helvetica"
        )
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = displayToImage(viewPoint)

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

            if let item = AnnotationFactory.makeAnnotation(
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

    private var supportedDrawingTool: Bool {
        switch state.selectedTool {
        case .rectangle, .filledRectangle, .ellipse, .line, .arrow, .pencil, .highlighter:
            true
        default:
            false
        }
    }
}
