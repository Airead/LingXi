//
//  AnnotationRenderer.swift
//  LingXi
//

import AppKit
import SwiftUI

nonisolated struct AnnotationRenderer {
    private let context: CGContext

    init(context: CGContext) {
        self.context = context
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
        case .line(let start, let end):
            renderLine(from: start, to: end, properties: item.properties)
        default:
            break
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

    // MARK: - Color conversion

    private func cgColor(from color: Color) -> CGColor {
        let nsColor = NSColor(color)
        return nsColor.usingColorSpace(.deviceRGB)?.cgColor ?? nsColor.cgColor
    }
}
