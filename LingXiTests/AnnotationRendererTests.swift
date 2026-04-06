//
//  AnnotationRendererTests.swift
//  LingXiTests
//

import AppKit
import SwiftUI
import Testing
@testable import LingXi

@Suite("AnnotationRenderer")
struct AnnotationRendererTests {

    private static let canvasWidth = 100
    private static let canvasHeight = 100

    private func makeContext() -> CGContext {
        CGContext(
            data: nil,
            width: Self.canvasWidth,
            height: Self.canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: Self.canvasWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    /// Read pixel at CGContext coordinates (y=0 at bottom).
    /// Bitmap data is stored top-to-bottom, so flip y.
    private func pixelColor(in context: CGContext, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow
        let flippedY = context.height - 1 - y
        let offset = flippedY * bytesPerRow + x * 4
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }

    private func makeProperties(
        strokeColor: Color = .red,
        fillColor: Color = .clear,
        strokeWidth: CGFloat = 1.0
    ) -> AnnotationProperties {
        AnnotationProperties(
            strokeColor: strokeColor,
            fillColor: fillColor,
            strokeWidth: strokeWidth,
            fontSize: 14.0,
            fontName: "Helvetica"
        )
    }

    // MARK: - Rectangle stroke

    @Test("renders stroked rectangle on canvas")
    func strokedRectangle() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .rectangle(CGRect(x: 10, y: 10, width: 30, height: 20)),
            bounds: CGRect(x: 10, y: 10, width: 30, height: 20),
            properties: makeProperties(strokeColor: .red, strokeWidth: 2.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Top edge of the rectangle should have non-zero alpha (red stroke)
        let edge = pixelColor(in: context, x: 20, y: 10)
        #expect(edge.a > 0, "Top edge should be painted")

        // Center of the rectangle should be empty (stroke only)
        let center = pixelColor(in: context, x: 25, y: 20)
        #expect(center.a == 0, "Center should be transparent for stroke-only rectangle")

        // Outside the rectangle should be empty
        let outside = pixelColor(in: context, x: 0, y: 0)
        #expect(outside.a == 0, "Outside should be transparent")
    }

    // MARK: - Filled rectangle

    @Test("renders filled rectangle on canvas")
    func filledRectangle() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .filledRectangle(CGRect(x: 10, y: 10, width: 30, height: 20)),
            bounds: CGRect(x: 10, y: 10, width: 30, height: 20),
            properties: makeProperties(strokeColor: .blue, fillColor: .blue, strokeWidth: 1.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Center should be filled
        let center = pixelColor(in: context, x: 25, y: 20)
        #expect(center.a > 0, "Center should be filled")
        #expect(center.b > center.r, "Fill should be blue")
    }

    // MARK: - Ellipse

    @Test("renders ellipse on canvas")
    func ellipse() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .ellipse(CGRect(x: 20, y: 20, width: 40, height: 40)),
            bounds: CGRect(x: 20, y: 20, width: 40, height: 40),
            properties: makeProperties(strokeColor: .green, strokeWidth: 2.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Top of the ellipse (center-x of bounding rect, top edge)
        let topEdge = pixelColor(in: context, x: 40, y: 20)
        #expect(topEdge.a > 0, "Top edge of ellipse should be painted")

        // Center of the ellipse should be empty (stroke only)
        let center = pixelColor(in: context, x: 40, y: 40)
        #expect(center.a == 0, "Center of ellipse should be transparent")
    }

    // MARK: - Line

    @Test("renders line on canvas")
    func line() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .line(start: CGPoint(x: 10, y: 50), end: CGPoint(x: 90, y: 50)),
            bounds: CGRect(x: 10, y: 49, width: 80, height: 2),
            properties: makeProperties(strokeColor: .red, strokeWidth: 2.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Middle of the line
        let mid = pixelColor(in: context, x: 50, y: 50)
        #expect(mid.a > 0, "Line midpoint should be painted")

        // Well away from the line
        let away = pixelColor(in: context, x: 50, y: 10)
        #expect(away.a == 0, "Point away from line should be transparent")
    }

    // MARK: - Multiple items

    @Test("renders multiple annotations")
    func multipleItems() {
        let context = makeContext()
        let rect = AnnotationItem(
            type: .rectangle(CGRect(x: 5, y: 5, width: 20, height: 20)),
            bounds: CGRect(x: 5, y: 5, width: 20, height: 20),
            properties: makeProperties(strokeColor: .red, strokeWidth: 1.0)
        )
        let line = AnnotationItem(
            type: .line(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 90, y: 90)),
            bounds: CGRect(x: 50, y: 50, width: 40, height: 40),
            properties: makeProperties(strokeColor: .blue, strokeWidth: 2.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([rect, line])

        let rectEdge = pixelColor(in: context, x: 15, y: 5)
        #expect(rectEdge.a > 0, "Rectangle edge should be painted")

        let lineMid = pixelColor(in: context, x: 70, y: 70)
        #expect(lineMid.a > 0, "Line midpoint should be painted")
    }

    // MARK: - Arrow

    @Test("renders arrow with shaft and arrowhead")
    func arrow() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .arrow(start: CGPoint(x: 10, y: 50), end: CGPoint(x: 90, y: 50)),
            bounds: CGRect(x: 10, y: 49, width: 80, height: 2),
            properties: makeProperties(strokeColor: .red, strokeWidth: 2.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Shaft midpoint should be painted
        let mid = pixelColor(in: context, x: 50, y: 50)
        #expect(mid.a > 0, "Arrow shaft midpoint should be painted")

        // Arrowhead tip (at end point) should be painted
        let tip = pixelColor(in: context, x: 89, y: 50)
        #expect(tip.a > 0, "Arrow tip area should be painted")

        // Well away from the arrow should be empty
        let away = pixelColor(in: context, x: 50, y: 10)
        #expect(away.a == 0, "Point away from arrow should be transparent")
    }

    @Test("arrow with zero length does not crash")
    func arrowZeroLength() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .arrow(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 50, y: 50)),
            bounds: CGRect(x: 50, y: 50, width: 0, height: 0),
            properties: makeProperties(strokeColor: .red, strokeWidth: 2.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])
        // Just verifying no crash
    }

    // MARK: - Path (freehand pencil)

    @Test("renders freehand path")
    func freehandPath() {
        let context = makeContext()
        let points = [
            CGPoint(x: 10, y: 50),
            CGPoint(x: 30, y: 50),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 70, y: 50),
            CGPoint(x: 90, y: 50),
        ]
        let item = AnnotationItem(
            type: .path(points),
            bounds: CGRect(x: 10, y: 49, width: 80, height: 2),
            properties: makeProperties(strokeColor: .red, strokeWidth: 3.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Points along the path should be painted
        let p1 = pixelColor(in: context, x: 30, y: 50)
        #expect(p1.a > 0, "Path point should be painted")

        let p2 = pixelColor(in: context, x: 70, y: 50)
        #expect(p2.a > 0, "Path point should be painted")

        // Well away from the path should be empty
        let away = pixelColor(in: context, x: 50, y: 10)
        #expect(away.a == 0, "Point away from path should be transparent")
    }

    @Test("path with fewer than 2 points does not render")
    func pathSinglePoint() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .path([CGPoint(x: 50, y: 50)]),
            bounds: CGRect(x: 50, y: 50, width: 0, height: 0),
            properties: makeProperties(strokeColor: .red, strokeWidth: 2.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        let pixel = pixelColor(in: context, x: 50, y: 50)
        #expect(pixel.a == 0, "Single point should not render")
    }

    // MARK: - Highlighter

    @Test("renders highlighter with semi-transparent wide stroke")
    func highlighter() {
        let context = makeContext()
        let points = [
            CGPoint(x: 10, y: 50),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 90, y: 50),
        ]
        let item = AnnotationItem(
            type: .highlight(points),
            bounds: CGRect(x: 10, y: 49, width: 80, height: 2),
            properties: makeProperties(strokeColor: .yellow, strokeWidth: 3.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Highlight path should be painted with semi-transparent alpha
        let mid = pixelColor(in: context, x: 50, y: 50)
        #expect(mid.a > 0, "Highlight midpoint should be painted")
        #expect(mid.a < 255, "Highlight should be semi-transparent")

        // Well away should be empty
        let away = pixelColor(in: context, x: 50, y: 10)
        #expect(away.a == 0, "Point away from highlight should be transparent")
    }

    // MARK: - Text

    @Test("renders text annotation")
    func textAnnotation() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .text("Hello"),
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20),
            properties: makeProperties(strokeColor: .red, strokeWidth: 1.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Text area should have painted pixels
        let textArea = pixelColor(in: context, x: 15, y: 18)
        #expect(textArea.a > 0, "Text area should be painted")
    }

    @Test("empty text does not render")
    func emptyText() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .text(""),
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20),
            properties: makeProperties()
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        let pixel = pixelColor(in: context, x: 15, y: 15)
        #expect(pixel.a == 0, "Empty text should not render")
    }

    // MARK: - Counter

    @Test("renders counter with filled circle and number")
    func counterAnnotation() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .counter(1),
            bounds: CGRect(x: 30, y: 30, width: 30, height: 30),
            properties: makeProperties(strokeColor: .red, strokeWidth: 1.0)
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Center of the counter circle should be painted
        let center = pixelColor(in: context, x: 45, y: 45)
        #expect(center.a > 0, "Counter center should be painted")

        // Well outside should be empty
        let outside = pixelColor(in: context, x: 5, y: 5)
        #expect(outside.a == 0, "Outside counter should be transparent")
    }

    // MARK: - Blur

    @Test("renders blur annotation when sourceImage is provided")
    func blurWithSourceImage() {
        let context = makeContext()
        // Create a source image with a solid red fill
        let sourceContext = CGContext(
            data: nil,
            width: Self.canvasWidth,
            height: Self.canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: Self.canvasWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        sourceContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        sourceContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let sourceImage = sourceContext.makeImage()!
        let blurManager = BlurCacheManager()

        let item = AnnotationItem(
            type: .blur(.pixelate),
            bounds: CGRect(x: 20, y: 20, width: 40, height: 40),
            properties: makeProperties()
        )

        let renderer = AnnotationRenderer(
            context: context,
            sourceImage: sourceImage,
            blurCacheManager: blurManager
        )
        renderer.render([item])

        // The blur region should have painted pixels
        let center = pixelColor(in: context, x: 40, y: 40)
        #expect(center.a > 0, "Blur region should be painted")
    }

    @Test("blur without sourceImage is a no-op")
    func blurWithoutSourceImage() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .blur(.pixelate),
            bounds: CGRect(x: 10, y: 10, width: 50, height: 50),
            properties: makeProperties()
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Should not crash, and nothing rendered
        let pixel = pixelColor(in: context, x: 30, y: 30)
        #expect(pixel.a == 0, "Blur without source should not render")
    }
}
