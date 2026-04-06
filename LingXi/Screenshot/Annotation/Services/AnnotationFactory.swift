//
//  AnnotationFactory.swift
//  LingXi
//

import Foundation
import SwiftUI

enum AnnotationFactory {
    static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func makeAnnotation(
        tool: AnnotationTool,
        from startPoint: CGPoint,
        to endPoint: CGPoint,
        properties: AnnotationProperties
    ) -> AnnotationItem? {
        let rect = normalizedRect(from: startPoint, to: endPoint)

        let type: AnnotationType
        switch tool {
        case .rectangle:
            type = .rectangle(rect)
        case .filledRectangle:
            type = .filledRectangle(rect)
        case .ellipse:
            type = .ellipse(rect)
        case .arrow:
            type = .arrow(start: startPoint, end: endPoint)
        case .line:
            type = .line(start: startPoint, end: endPoint)
        case .blur:
            type = .blur(properties.blurType)
        default:
            return nil
        }

        return AnnotationItem(type: type, bounds: rect, properties: properties)
    }

    static func makePathAnnotation(
        tool: AnnotationTool,
        points: [CGPoint],
        properties: AnnotationProperties
    ) -> AnnotationItem? {
        guard points.count >= 2 else { return nil }

        var minX = points[0].x, maxX = minX
        var minY = points[0].y, maxY = minY
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        let type: AnnotationType
        switch tool {
        case .pencil:
            type = .path(points)
        case .highlighter:
            type = .highlight(points)
        default:
            return nil
        }

        return AnnotationItem(type: type, bounds: bounds, properties: properties)
    }

    static func makeTextAnnotation(
        at position: CGPoint,
        text: String,
        properties: AnnotationProperties
    ) -> AnnotationItem {
        let size = (text as NSString).size(withAttributes: properties.textAttributes())
        let bounds = CGRect(origin: position, size: size)

        return AnnotationItem(
            type: .text(text),
            bounds: bounds,
            properties: properties
        )
    }

    static func makeCounterAnnotation(
        at position: CGPoint,
        number: Int,
        properties: AnnotationProperties
    ) -> AnnotationItem {
        let diameter = max(24, properties.fontSize * 1.6)
        let bounds = CGRect(
            x: position.x - diameter / 2,
            y: position.y - diameter / 2,
            width: diameter,
            height: diameter
        )

        return AnnotationItem(
            type: .counter(number),
            bounds: bounds,
            properties: properties
        )
    }
}
