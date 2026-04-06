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
}
