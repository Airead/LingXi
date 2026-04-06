//
//  AnnotationTool.swift
//  LingXi
//

enum AnnotationTool: String, CaseIterable, Identifiable {
    case selection
    case rectangle
    case filledRectangle
    case ellipse
    case arrow
    case line
    case pencil
    case text
    case highlighter
    case blur
    case counter
    case crop

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .selection: "cursorarrow"
        case .rectangle: "rectangle"
        case .filledRectangle: "rectangle.fill"
        case .ellipse: "oval"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .pencil: "pencil.tip"
        case .text: "textformat"
        case .highlighter: "highlighter"
        case .blur: "square.on.square.squareshape.controlhandles"
        case .counter: "number.circle"
        case .crop: "crop"
        }
    }

    var shortcutKey: Character {
        switch self {
        case .selection: "v"
        case .rectangle: "r"
        case .filledRectangle: "u"
        case .ellipse: "o"
        case .arrow: "a"
        case .line: "l"
        case .pencil: "p"
        case .text: "t"
        case .highlighter: "h"
        case .blur: "b"
        case .counter: "n"
        case .crop: "c"
        }
    }

    var isPathBased: Bool {
        switch self {
        case .pencil, .highlighter:
            true
        default:
            false
        }
    }

    var displayName: String {
        switch self {
        case .selection: "Selection"
        case .rectangle: "Rectangle"
        case .filledRectangle: "Filled Rectangle"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .line: "Line"
        case .pencil: "Pencil"
        case .text: "Text"
        case .highlighter: "Highlighter"
        case .blur: "Blur"
        case .counter: "Counter"
        case .crop: "Crop"
        }
    }
}
