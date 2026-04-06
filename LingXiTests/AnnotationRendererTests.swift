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

    // MARK: - Unsupported type is a no-op

    @Test("unsupported annotation type does not crash")
    func unsupportedType() {
        let context = makeContext()
        let item = AnnotationItem(
            type: .text("hello"),
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20),
            properties: makeProperties()
        )

        let renderer = AnnotationRenderer(context: context)
        renderer.render([item])

        // Just verifying no crash
        let pixel = pixelColor(in: context, x: 0, y: 0)
        #expect(pixel.a == 0)
    }
}
