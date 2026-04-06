//
//  ImageExporterTests.swift
//  LingXiTests
//

import AppKit
import SwiftUI
import Testing
@testable import LingXi

@Suite("ImageExporter")
struct ImageExporterTests {

    private static let imageWidth = 200
    private static let imageHeight = 100
    private static var pointSize: CGSize {
        CGSize(width: imageWidth, height: imageHeight)
    }

    private func makeProperties(
        strokeColor: Color = .red,
        strokeWidth: CGFloat = 2.0
    ) -> AnnotationProperties {
        AnnotationProperties(
            strokeColor: strokeColor,
            fillColor: .clear,
            strokeWidth: strokeWidth,
            fontSize: 14.0,
            fontName: "Helvetica"
        )
    }

    // MARK: - Pixel helpers

    /// Read pixel data from a CGImage into an accessible buffer.
    private func pixelBuffer(for image: CGImage) -> (context: CGContext, data: UnsafeMutablePointer<UInt8>) {
        let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (ctx, ctx.data!.assumingMemoryBound(to: UInt8.self))
    }

    // MARK: - renderFinalImage

    @Test("renders source image preserving resolution without annotations")
    func renderNoAnnotations() {
        let source = makeTestImage(width: Self.imageWidth, height: Self.imageHeight)
        let result = ImageExporter.renderFinalImage(source: source, imagePointSize: Self.pointSize, annotations: [])

        #expect(result != nil)
        #expect(result!.width == Self.imageWidth)
        #expect(result!.height == Self.imageHeight)
    }

    @Test("renders source image with annotations composited")
    func renderWithAnnotations() {
        let source = makeTestImage(width: Self.imageWidth, height: Self.imageHeight)
        let annotation = AnnotationItem(
            type: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 30)),
            bounds: CGRect(x: 10, y: 10, width: 50, height: 30),
            properties: makeProperties(strokeColor: .red, strokeWidth: 3.0)
        )

        guard let composited = ImageExporter.renderFinalImage(source: source, imagePointSize: Self.pointSize, annotations: [annotation]) else {
            Issue.record("renderFinalImage returned nil")
            return
        }

        let (ctx, data) = pixelBuffer(for: composited)

        // Check a pixel on the rectangle stroke (top edge, at x=30 y=10 in image coords)
        // In CGContext bitmap, y=0 is bottom, so flip
        let flippedY = composited.height - 1 - 10
        let offset = flippedY * ctx.bytesPerRow + 30 * 4
        let r = data[offset]
        #expect(r > 0, "Annotation stroke should add red to the composited image")
    }

    @Test("annotations scale correctly on Retina (2x) images")
    func retinaScaling() {
        // Simulate 2x Retina: pixel size is 400x200, point size is 200x100
        let source = makeTestImage(width: Self.imageWidth * 2, height: Self.imageHeight * 2)
        let annotation = AnnotationItem(
            type: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 30)),
            bounds: CGRect(x: 10, y: 10, width: 50, height: 30),
            properties: makeProperties(strokeColor: .red, strokeWidth: 3.0)
        )

        guard let composited = ImageExporter.renderFinalImage(
            source: source,
            imagePointSize: Self.pointSize,
            annotations: [annotation]
        ) else {
            Issue.record("renderFinalImage returned nil")
            return
        }

        #expect(composited.width == Self.imageWidth * 2)
        #expect(composited.height == Self.imageHeight * 2)

        let (ctx, data) = pixelBuffer(for: composited)

        // The annotation at point (30, 10) should map to pixel (60, 20) on a 2x display
        let flippedY = composited.height - 1 - 20
        let offset = flippedY * ctx.bytesPerRow + 60 * 4
        let r = data[offset]
        #expect(r > 0, "Annotation stroke should appear at scaled pixel position on Retina")
    }

    // MARK: - copyToClipboard

    @Test("copies image to custom pasteboard as PNG")
    func copyToClipboard() {
        let source = makeTestImage(width: Self.imageWidth, height: Self.imageHeight)
        let image = ImageExporter.renderFinalImage(source: source, imagePointSize: Self.pointSize, annotations: [])!

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.airead.lingxi.test.exporter"))
        defer { pasteboard.releaseGlobally() }

        ImageExporter.copyToClipboard(image, pasteboard: pasteboard)

        let pngData = pasteboard.data(forType: .png)
        #expect(pngData != nil, "Pasteboard should contain PNG data")
        #expect(pngData!.count > 0)
    }

    // MARK: - saveToFile

    @Test("saves image as PNG")
    func savePNG() throws {
        let source = makeTestImage(width: Self.imageWidth, height: Self.imageHeight)
        let image = ImageExporter.renderFinalImage(source: source, imagePointSize: Self.pointSize, annotations: [])!

        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent("test_export_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }

        try ImageExporter.saveToFile(image, url: path, format: .png)

        let savedData = try Data(contentsOf: path)
        #expect(savedData.count > 0, "Saved PNG file should not be empty")

        // Verify it's valid PNG by loading it
        let loaded = NSImage(data: savedData)
        #expect(loaded != nil, "Saved file should be a valid image")
    }

    @Test("saves image as JPEG")
    func saveJPEG() throws {
        let source = makeTestImage(width: Self.imageWidth, height: Self.imageHeight)
        let image = ImageExporter.renderFinalImage(source: source, imagePointSize: Self.pointSize, annotations: [])!

        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent("test_export_\(UUID().uuidString).jpeg")
        defer { try? FileManager.default.removeItem(at: path) }

        try ImageExporter.saveToFile(image, url: path, format: .jpeg, jpegQuality: 0.8)

        let savedData = try Data(contentsOf: path)
        #expect(savedData.count > 0, "Saved JPEG file should not be empty")

        let loaded = NSImage(data: savedData)
        #expect(loaded != nil, "Saved file should be a valid image")
    }

    @Test("JPEG quality affects file size")
    func jpegQualityAffectsSize() throws {
        let source = makeTestImage(width: Self.imageWidth, height: Self.imageHeight)
        let image = ImageExporter.renderFinalImage(source: source, imagePointSize: Self.pointSize, annotations: [])!

        let tempDir = FileManager.default.temporaryDirectory
        let pathLow = tempDir.appendingPathComponent("test_export_low_\(UUID().uuidString).jpeg")
        let pathHigh = tempDir.appendingPathComponent("test_export_high_\(UUID().uuidString).jpeg")
        defer {
            try? FileManager.default.removeItem(at: pathLow)
            try? FileManager.default.removeItem(at: pathHigh)
        }

        try ImageExporter.saveToFile(image, url: pathLow, format: .jpeg, jpegQuality: 0.1)
        try ImageExporter.saveToFile(image, url: pathHigh, format: .jpeg, jpegQuality: 1.0)

        let lowSize = try Data(contentsOf: pathLow).count
        let highSize = try Data(contentsOf: pathHigh).count
        #expect(lowSize < highSize, "Low quality JPEG should be smaller than high quality")
    }

    // MARK: - ImageFormat

    @Test("ImageFormat has correct file extensions")
    func formatExtensions() {
        #expect(ImageFormat.png.fileExtension == "png")
        #expect(ImageFormat.jpeg.fileExtension == "jpeg")
    }

    @Test("ImageFormat has correct labels")
    func formatLabels() {
        #expect(ImageFormat.png.label == "PNG")
        #expect(ImageFormat.jpeg.label == "JPEG")
    }
}
