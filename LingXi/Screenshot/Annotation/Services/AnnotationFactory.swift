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
        case .line:
            type = .line(start: startPoint, end: endPoint)
        default:
            return nil
        }

        return AnnotationItem(type: type, bounds: rect, properties: properties)
    }
}
