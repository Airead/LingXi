//
//  AnnotationFactory.swift
//  LingXi
//

import Foundation
import SwiftUI

enum AnnotationFactory {
    static func makeAnnotation(
        tool: AnnotationTool,
        from startPoint: CGPoint,
        to endPoint: CGPoint,
        properties: AnnotationProperties
    ) -> AnnotationItem? {
        let rect = CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )

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
}
