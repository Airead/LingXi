//
//  AnnotationCanvasViewTests.swift
//  LingXiTests
//

import AppKit
import SwiftUI
import Testing
@testable import LingXi

@Suite("AnnotationCanvasView")
@MainActor
struct AnnotationCanvasViewTests {

    private func makeImage(width: Int = 200, height: Int = 100) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    private func makeCanvas(imageWidth: Int = 200, imageHeight: Int = 100, viewWidth: CGFloat = 400, viewHeight: CGFloat = 200) -> AnnotationCanvasNSView {
        let state = AnnotationState(sourceImage: makeImage(width: imageWidth, height: imageHeight))
        let canvas = AnnotationCanvasNSView(state: state)
        canvas.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
        return canvas
    }

    // MARK: - Coordinate conversion

    @Test("displayScale is aspect-fit ratio")
    func displayScaleAspectFit() {
        let canvas = makeCanvas(imageWidth: 200, imageHeight: 100, viewWidth: 400, viewHeight: 400)
        // Aspect fit: min(400/200, 400/100) = min(2.0, 4.0) = 2.0
        let origin = canvas.imageToDisplay(CGPoint(x: 0, y: 0))
        let corner = canvas.imageToDisplay(CGPoint(x: 200, y: 100))

        let scaledWidth = corner.x - origin.x
        let scaledHeight = corner.y - origin.y
        #expect(abs(scaledWidth - 400) < 0.01, "Width should be 200 * 2.0 = 400")
        #expect(abs(scaledHeight - 200) < 0.01, "Height should be 100 * 2.0 = 200")
    }

    @Test("image is centered in view")
    func imageCenteredInView() {
        let canvas = makeCanvas(imageWidth: 200, imageHeight: 100, viewWidth: 400, viewHeight: 400)
        // Scale = 2.0, scaled size = 400x200, centered in 400x400
        // Origin offset: x = (400-400)/2 = 0, y = (400-200)/2 = 100
        let origin = canvas.imageToDisplay(CGPoint(x: 0, y: 0))
        #expect(abs(origin.x - 0) < 0.01)
        #expect(abs(origin.y - 100) < 0.01)
    }

    @Test("displayToImage is inverse of imageToDisplay")
    func roundTripConversion() {
        let canvas = makeCanvas(imageWidth: 300, imageHeight: 150, viewWidth: 600, viewHeight: 400)
        let original = CGPoint(x: 75.5, y: 42.3)
        let display = canvas.imageToDisplay(original)
        let back = canvas.displayToImage(display)

        #expect(abs(back.x - original.x) < 0.01)
        #expect(abs(back.y - original.y) < 0.01)
    }

    @Test("displayToImage handles non-uniform aspect ratio")
    func nonUniformAspect() {
        // Image is 100x400 in a 200x200 view
        // Scale = min(200/100, 200/400) = min(2.0, 0.5) = 0.5
        let canvas = makeCanvas(imageWidth: 100, imageHeight: 400, viewWidth: 200, viewHeight: 200)
        let origin = canvas.imageToDisplay(CGPoint(x: 0, y: 0))
        let corner = canvas.imageToDisplay(CGPoint(x: 100, y: 400))

        let scaledWidth = corner.x - origin.x
        let scaledHeight = corner.y - origin.y
        #expect(abs(scaledWidth - 50) < 0.01, "Width should be 100 * 0.5 = 50")
        #expect(abs(scaledHeight - 200) < 0.01, "Height should be 400 * 0.5 = 200")
    }
}

// MARK: - AnnotationFactory

@Suite("AnnotationFactory")
struct AnnotationFactoryTests {

    private func makeProperties() -> AnnotationProperties {
        AnnotationProperties(
            strokeColor: .red,
            fillColor: .clear,
            strokeWidth: 2.0,
            fontSize: 14.0,
            fontName: "Helvetica"
        )
    }

    @Test("creates rectangle from two points")
    func rectangleFromPoints() {
        let item = AnnotationFactory.makeAnnotation(
            tool: .rectangle,
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 60, y: 80),
            properties: makeProperties()
        )
        #expect(item != nil)
        if case .rectangle(let rect) = item?.type {
            #expect(rect == CGRect(x: 10, y: 20, width: 50, height: 60))
        } else {
            Issue.record("Expected rectangle type")
        }
    }

    @Test("creates rectangle with reversed points (drag bottom-right to top-left)")
    func rectangleReversedPoints() {
        let item = AnnotationFactory.makeAnnotation(
            tool: .rectangle,
            from: CGPoint(x: 60, y: 80),
            to: CGPoint(x: 10, y: 20),
            properties: makeProperties()
        )
        if case .rectangle(let rect) = item?.type {
            #expect(rect == CGRect(x: 10, y: 20, width: 50, height: 60))
        } else {
            Issue.record("Expected rectangle type")
        }
    }

    @Test("creates filled rectangle")
    func filledRectangle() {
        let item = AnnotationFactory.makeAnnotation(
            tool: .filledRectangle,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 30, y: 40),
            properties: makeProperties()
        )
        if case .filledRectangle(let rect) = item?.type {
            #expect(rect == CGRect(x: 0, y: 0, width: 30, height: 40))
        } else {
            Issue.record("Expected filledRectangle type")
        }
    }

    @Test("creates ellipse")
    func ellipse() {
        let item = AnnotationFactory.makeAnnotation(
            tool: .ellipse,
            from: CGPoint(x: 5, y: 5),
            to: CGPoint(x: 55, y: 45),
            properties: makeProperties()
        )
        if case .ellipse(let rect) = item?.type {
            #expect(rect == CGRect(x: 5, y: 5, width: 50, height: 40))
        } else {
            Issue.record("Expected ellipse type")
        }
    }

    @Test("creates line preserving start and end points")
    func line() {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 90, y: 80)
        let item = AnnotationFactory.makeAnnotation(
            tool: .line,
            from: start,
            to: end,
            properties: makeProperties()
        )
        if case .line(let s, let e) = item?.type {
            #expect(s == start)
            #expect(e == end)
        } else {
            Issue.record("Expected line type")
        }
    }

    @Test("creates arrow preserving start and end points")
    func arrow() {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 90, y: 80)
        let item = AnnotationFactory.makeAnnotation(
            tool: .arrow,
            from: start,
            to: end,
            properties: makeProperties()
        )
        #expect(item != nil)
        if case .arrow(let s, let e) = item?.type {
            #expect(s == start)
            #expect(e == end)
        } else {
            Issue.record("Expected arrow type")
        }
    }

    @Test("unsupported tool returns nil")
    func unsupportedTool() {
        let item = AnnotationFactory.makeAnnotation(
            tool: .text,
            from: .zero,
            to: CGPoint(x: 50, y: 50),
            properties: makeProperties()
        )
        #expect(item == nil)
    }

    @Test("bounds are correctly set for all supported tools")
    func boundsCorrectness() {
        let start = CGPoint(x: 30, y: 10)
        let end = CGPoint(x: 10, y: 50)
        let expectedBounds = CGRect(x: 10, y: 10, width: 20, height: 40)

        for tool in [AnnotationTool.rectangle, .filledRectangle, .ellipse, .line, .arrow] {
            let item = AnnotationFactory.makeAnnotation(
                tool: tool,
                from: start,
                to: end,
                properties: makeProperties()
            )
            #expect(item?.bounds == expectedBounds, "Bounds should be normalized for \(tool)")
        }
    }

    // MARK: - Path annotation factory

    @Test("creates pencil path annotation from points")
    func pencilPath() {
        let points = [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 60), CGPoint(x: 90, y: 30)]
        let item = AnnotationFactory.makePathAnnotation(
            tool: .pencil,
            points: points,
            properties: makeProperties()
        )
        #expect(item != nil)
        if case .path(let p) = item?.type {
            #expect(p == points)
        } else {
            Issue.record("Expected path type")
        }
        #expect(item?.bounds == CGRect(x: 10, y: 20, width: 80, height: 40))
    }

    @Test("creates highlighter annotation from points")
    func highlighterPath() {
        let points = [CGPoint(x: 5, y: 10), CGPoint(x: 95, y: 10)]
        let item = AnnotationFactory.makePathAnnotation(
            tool: .highlighter,
            points: points,
            properties: makeProperties()
        )
        #expect(item != nil)
        if case .highlight(let p) = item?.type {
            #expect(p == points)
        } else {
            Issue.record("Expected highlight type")
        }
    }

    @Test("path annotation with fewer than 2 points returns nil")
    func pathTooFewPoints() {
        let item = AnnotationFactory.makePathAnnotation(
            tool: .pencil,
            points: [CGPoint(x: 10, y: 20)],
            properties: makeProperties()
        )
        #expect(item == nil)
    }

    @Test("path annotation with unsupported tool returns nil")
    func pathUnsupportedTool() {
        let item = AnnotationFactory.makePathAnnotation(
            tool: .rectangle,
            points: [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 60)],
            properties: makeProperties()
        )
        #expect(item == nil)
    }

    // MARK: - Text annotation factory

    @Test("creates text annotation at position")
    func textAnnotation() {
        let position = CGPoint(x: 20, y: 30)
        let item = AnnotationFactory.makeTextAnnotation(
            at: position,
            text: "Hello",
            properties: makeProperties()
        )
        if case .text(let t) = item.type {
            #expect(t == "Hello")
        } else {
            Issue.record("Expected text type")
        }
        #expect(item.bounds.origin == position)
        #expect(item.bounds.width > 0)
        #expect(item.bounds.height > 0)
    }

    // MARK: - Blur annotation factory

    @Test("creates blur annotation with blur type")
    func blurAnnotation() {
        let props = AnnotationProperties(
            strokeColor: .red, fillColor: .clear, strokeWidth: 2.0,
            fontSize: 14.0, fontName: "Helvetica", blurType: .gaussian
        )
        let item = AnnotationFactory.makeAnnotation(
            tool: .blur,
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 60, y: 70),
            properties: props
        )
        #expect(item != nil)
        if case .blur(let type) = item?.type {
            #expect(type == .gaussian)
        } else {
            Issue.record("Expected blur type")
        }
        #expect(item?.bounds == CGRect(x: 10, y: 20, width: 50, height: 50))
    }

    @Test("creates counter annotation centered at position")
    func counterAnnotation() {
        let position = CGPoint(x: 50, y: 50)
        let item = AnnotationFactory.makeCounterAnnotation(
            at: position,
            number: 3,
            properties: makeProperties()
        )
        if case .counter(let n) = item.type {
            #expect(n == 3)
        } else {
            Issue.record("Expected counter type")
        }
        // Bounds should be centered on the position
        let tolerance: CGFloat = 0.01
        #expect(abs(item.bounds.midX - position.x) < tolerance)
        #expect(abs(item.bounds.midY - position.y) < tolerance)
        #expect(item.bounds.width > 0)
    }
}
