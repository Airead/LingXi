//
//  AnnotationItem.swift
//  LingXi
//

import SwiftUI

enum BlurType: Equatable, Hashable {
    case pixelate
    case gaussian

    var label: String {
        switch self {
        case .pixelate: "Mosaic"
        case .gaussian: "Gaussian"
        }
    }

    var systemImage: String {
        switch self {
        case .pixelate: "squareshape.split.3x3"
        case .gaussian: "aqi.medium"
        }
    }
}

enum AnnotationType: Equatable {
    case rectangle(CGRect)
    case filledRectangle(CGRect)
    case ellipse(CGRect)
    case arrow(start: CGPoint, end: CGPoint)
    case line(start: CGPoint, end: CGPoint)
    case path([CGPoint])
    case text(String)
    case highlight([CGPoint])
    case blur(BlurType)
    case counter(Int)
}

extension AnnotationType {
    var isArrow: Bool {
        if case .arrow = self { return true }
        return false
    }
}

struct AnnotationProperties: Equatable {
    var strokeColor: Color
    var fillColor: Color
    var strokeWidth: CGFloat
    var fontSize: CGFloat
    var fontName: String
    var blurType: BlurType = .pixelate

    nonisolated func textFont() -> NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    }

    nonisolated func textAttributes() -> [NSAttributedString.Key: Any] {
        [.font: textFont(), .foregroundColor: NSColor(strokeColor)]
    }
}

struct AnnotationItem: Identifiable, Equatable {
    let id: UUID
    var type: AnnotationType
    var bounds: CGRect
    var properties: AnnotationProperties

    init(
        id: UUID = UUID(),
        type: AnnotationType,
        bounds: CGRect,
        properties: AnnotationProperties
    ) {
        self.id = id
        self.type = type
        self.bounds = bounds
        self.properties = properties
    }

    // MARK: - Transform

    func translated(by delta: CGSize) -> AnnotationItem {
        let newBounds = bounds.offsetBy(dx: delta.width, dy: delta.height)
        let newType: AnnotationType
        switch type {
        case .rectangle(let r):
            newType = .rectangle(r.offsetBy(dx: delta.width, dy: delta.height))
        case .filledRectangle(let r):
            newType = .filledRectangle(r.offsetBy(dx: delta.width, dy: delta.height))
        case .ellipse(let r):
            newType = .ellipse(r.offsetBy(dx: delta.width, dy: delta.height))
        case .arrow(let s, let e):
            newType = .arrow(start: s.translated(by: delta), end: e.translated(by: delta))
        case .line(let s, let e):
            newType = .line(start: s.translated(by: delta), end: e.translated(by: delta))
        case .path(let points):
            newType = .path(points.map { $0.translated(by: delta) })
        case .highlight(let points):
            newType = .highlight(points.map { $0.translated(by: delta) })
        case .text, .counter, .blur:
            newType = type
        }
        return AnnotationItem(id: id, type: newType, bounds: newBounds, properties: properties)
    }
}

private extension CGPoint {
    func translated(by delta: CGSize) -> CGPoint {
        CGPoint(x: x + delta.width, y: y + delta.height)
    }
}
