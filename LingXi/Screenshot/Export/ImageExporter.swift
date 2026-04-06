//
//  ImageExporter.swift
//  LingXi
//

import AppKit

enum ImageFormat: String, CaseIterable {
    case png
    case jpeg

    var label: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        }
    }

    var fileExtension: String { rawValue }
}

struct ImageExporter {

    // MARK: - Render

    /// Render the source image with all annotations composited at native resolution.
    /// - Parameters:
    ///   - source: The source CGImage (pixel dimensions).
    ///   - imagePointSize: The NSImage.size in points. Annotations are stored in this coordinate space.
    ///     On Retina displays the pixel size is typically 2x the point size.
    ///   - annotations: Annotations to composite.
    ///   - blurCacheManager: Optional blur cache for blur annotations.
    nonisolated static func renderFinalImage(
        source: CGImage,
        imagePointSize: CGSize,
        annotations: [AnnotationItem],
        blurCacheManager: BlurCacheManager? = nil
    ) -> CGImage? {
        let width = source.width
        let height = source.height
        let colorSpace = source.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Top-left origin to match AnnotationRenderer's flipped coordinate system
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        // CGContext.draw expects bottom-left origin, so locally flip back
        let pixelSize = CGSize(width: width, height: height)
        context.saveGState()
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(source, in: CGRect(origin: .zero, size: pixelSize))
        context.restoreGState()

        // Scale from point coordinates (annotation space) to pixel coordinates
        let scaleX = CGFloat(width) / imagePointSize.width
        let scaleY = CGFloat(height) / imagePointSize.height
        context.scaleBy(x: scaleX, y: scaleY)

        let renderer = AnnotationRenderer(
            context: context,
            sourceImage: source,
            blurCacheManager: blurCacheManager
        )
        renderer.render(annotations)

        return context.makeImage()
    }

    // MARK: - Clipboard

    /// Copy a CGImage to the pasteboard as PNG data.
    nonisolated static func copyToClipboard(_ image: CGImage, pasteboard: NSPasteboard = .general) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    // MARK: - Save to file

    /// Save a CGImage to a file in the specified format.
    nonisolated static func saveToFile(
        _ image: CGImage,
        url: URL,
        format: ImageFormat,
        jpegQuality: CGFloat = 0.9
    ) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)

        let data: Data?
        switch format {
        case .png:
            data = bitmap.representation(using: .png, properties: [:])
        case .jpeg:
            data = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: jpegQuality]
            )
        }

        guard let fileData = data else {
            throw ImageExportError.encodingFailed(format)
        }

        try fileData.write(to: url, options: .atomic)
    }
}

enum ImageExportError: Error, LocalizedError {
    case encodingFailed(ImageFormat)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let format):
            "Failed to encode image as \(format.label)"
        }
    }
}
