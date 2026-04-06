//
//  AnnotationRenderer.swift
//  LingXi
//

import AppKit
import SwiftUI

nonisolated struct AnnotationRenderer {
    private let context: CGContext
    private let nsContext: NSGraphicsContext
    private let sourceImage: CGImage?
    private let blurCacheManager: BlurCacheManager?

    init(context: CGContext, sourceImage: CGImage? = nil, blurCacheManager: BlurCacheManager? = nil) {
        self.context = context
        self.nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        self.sourceImage = sourceImage
        self.blurCacheManager = blurCacheManager
    }

    func render(_ items: [AnnotationItem]) {
        for item in items {
            context.saveGState()
            renderItem(item)
            context.restoreGState()
        }
    }

    private func renderItem(_ item: AnnotationItem) {
        switch item.type {
        case .rectangle(let rect):
            renderRectangle(rect, properties: item.properties, filled: false)
        case .filledRectangle(let rect):
            renderRectangle(rect, properties: item.properties, filled: true)
        case .ellipse(let rect):
            renderEllipse(rect, properties: item.properties)
        case .arrow(let start, let end):
            renderArrow(from: start, to: end, properties: item.properties)
        case .line(let start, let end):
            renderLine(from: start, to: end, properties: item.properties)
        case .path(let points):
            renderPath(points, properties: item.properties)
        case .highlight(let points):
            renderHighlight(points, properties: item.properties)
        case .text(let text):
            renderText(text, bounds: item.bounds, properties: item.properties)
        case .counter(let number):
            renderCounter(number, bounds: item.bounds, properties: item.properties)
        case .blur(let blurType):
            renderBlur(blurType, bounds: item.bounds)
        }
    }

    // MARK: - Shapes

    private func renderRectangle(_ rect: CGRect, properties: AnnotationProperties, filled: Bool) {
        if filled {
            context.setFillColor(cgColor(from: properties.fillColor))
            context.fill(rect)
        }
        context.setStrokeColor(cgColor(from: properties.strokeColor))
        context.setLineWidth(properties.strokeWidth)
        context.stroke(rect)
    }

    private func renderEllipse(_ rect: CGRect, properties: AnnotationProperties) {
        context.setStrokeColor(cgColor(from: properties.strokeColor))
        context.setLineWidth(properties.strokeWidth)
        context.strokeEllipse(in: rect)
    }

    private func renderLine(from start: CGPoint, to end: CGPoint, properties: AnnotationProperties) {
        context.setStrokeColor(cgColor(from: properties.strokeColor))
        context.setLineWidth(properties.strokeWidth)
        context.strokeLineSegments(between: [start, end])
    }

    // MARK: - Arrow

    private func renderArrow(from start: CGPoint, to end: CGPoint, properties: AnnotationProperties) {
        let color = cgColor(from: properties.strokeColor)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }

        // Unit direction and perpendicular vectors
        let ux = dx / length
        let uy = dy / length
        let px = -uy  // perpendicular
        let py = ux

        // Tapered body: thin at start, slightly widens toward the head
        let tailHalfWidth = properties.strokeWidth * 0.15
        let bodyHalfWidth = properties.strokeWidth * 0.6

        // Arrowhead: much wider than body for a prominent triangle
        let headLength = min(max(16, properties.strokeWidth * 6), length * 0.45)
        let headHalfWidth = properties.strokeWidth * 3

        // Point where the arrowhead base meets the body
        let headBase = CGPoint(
            x: end.x - headLength * ux,
            y: end.y - headLength * uy
        )

        // Build the filled shape: start(thin) -> headBase(medium) -> wing(wide) -> tip -> wing -> headBase -> start
        let tailL = CGPoint(x: start.x + px * tailHalfWidth, y: start.y + py * tailHalfWidth)
        let tailR = CGPoint(x: start.x - px * tailHalfWidth, y: start.y - py * tailHalfWidth)
        let bodyL = CGPoint(x: headBase.x + px * bodyHalfWidth, y: headBase.y + py * bodyHalfWidth)
        let bodyR = CGPoint(x: headBase.x - px * bodyHalfWidth, y: headBase.y - py * bodyHalfWidth)
        let wingL = CGPoint(x: headBase.x + px * headHalfWidth, y: headBase.y + py * headHalfWidth)
        let wingR = CGPoint(x: headBase.x - px * headHalfWidth, y: headBase.y - py * headHalfWidth)

        context.setFillColor(color)
        context.beginPath()
        context.move(to: tailR)
        context.addLine(to: tailL)
        context.addLine(to: bodyL)
        context.addLine(to: wingL)
        context.addLine(to: end)
        context.addLine(to: wingR)
        context.addLine(to: bodyR)
        context.closePath()
        context.fillPath()
    }

    // MARK: - Path / Highlight

    private func renderPath(_ points: [CGPoint], properties: AnnotationProperties) {
        strokePoints(points, color: cgColor(from: properties.strokeColor), lineWidth: properties.strokeWidth)
    }

    private func renderHighlight(_ points: [CGPoint], properties: AnnotationProperties) {
        let baseColor = NSColor(properties.strokeColor)
            .withAlphaComponent(0.35)
            .usingColorSpace(.deviceRGB)?.cgColor
            ?? NSColor(properties.strokeColor).cgColor
        strokePoints(points, color: baseColor, lineWidth: properties.strokeWidth * 4)
    }

    private func strokePoints(_ points: [CGPoint], color: CGColor, lineWidth: CGFloat) {
        guard points.count >= 2 else { return }
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.beginPath()
        context.move(to: points[0])
        for i in 1..<points.count {
            context.addLine(to: points[i])
        }
        context.strokePath()
    }

    // MARK: - Text

    private func renderText(_ text: String, bounds: CGRect, properties: AnnotationProperties) {
        guard !text.isEmpty else { return }
        drawAttributedString(NSAttributedString(string: text, attributes: properties.textAttributes()), at: bounds.origin)
    }

    // MARK: - Counter

    private func renderCounter(_ number: Int, bounds: CGRect, properties: AnnotationProperties) {
        context.setFillColor(cgColor(from: properties.strokeColor))
        context.fillEllipse(in: bounds)

        let font = NSFont.monospacedSystemFont(ofSize: bounds.width * 0.5, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attrString = NSAttributedString(string: "\(number)", attributes: attributes)
        let textSize = attrString.size()
        let textOrigin = CGPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2
        )
        drawAttributedString(attrString, at: textOrigin)
    }

    private func drawAttributedString(_ attrString: NSAttributedString, at point: CGPoint) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        attrString.draw(at: point)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Blur

    private func renderBlur(_ blurType: BlurType, bounds: CGRect) {
        guard let sourceImage, let blurCacheManager else { return }
        let rect = bounds.integral
        guard rect.width > 0, rect.height > 0 else { return }

        let imageSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let cgRect = rect.verticallyFlipped(imageHeight: imageSize.height)

        guard let blurred = blurCacheManager.blurredImage(
            source: sourceImage,
            rect: cgRect,
            blurType: blurType
        ) else { return }

        context.saveGState()
        context.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(blurred, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    // MARK: - Crop overlay

    func renderCropOverlay(rect: CGRect, imageSize: CGSize) {
        context.setFillColor(CGColor(gray: 0, alpha: 0.5))

        context.fill(CGRect(x: 0, y: 0, width: imageSize.width, height: rect.minY))
        context.fill(CGRect(x: 0, y: rect.maxY, width: imageSize.width, height: imageSize.height - rect.maxY))
        context.fill(CGRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height))
        context.fill(CGRect(x: rect.maxX, y: rect.minY, width: imageSize.width - rect.maxX, height: rect.height))

        context.setStrokeColor(CGColor.white)
        context.setLineWidth(1.0)
        context.stroke(rect)
    }

    // MARK: - Color conversion

    private func cgColor(from color: Color) -> CGColor {
        let nsColor = NSColor(color)
        return nsColor.usingColorSpace(.deviceRGB)?.cgColor ?? nsColor.cgColor
    }
}
