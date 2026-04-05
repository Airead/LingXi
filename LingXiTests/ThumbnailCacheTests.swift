import AppKit
import Testing
@testable import LingXi

struct ThumbnailCacheTests {

    private func createTestImage(size: NSSize = NSSize(width: 10, height: 10)) -> (URL, NSImage) {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return (url, image)
    }

    @Test func loadImageCachesResult() async {
        let cache = ThumbnailCache.shared
        let (url, _) = createTestImage()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await cache.image(for: url) == nil)
        let loaded = await cache.loadImage(for: url)
        #expect(loaded != nil)
        #expect(await cache.image(for: url) != nil)
    }

    @Test func loadImageReturnsCachedOnSecondCall() async {
        let cache = ThumbnailCache.shared
        let (url, _) = createTestImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = await cache.loadImage(for: url)
        let second = await cache.loadImage(for: url)
        #expect(first === second)
    }

    @Test func loadImageReturnsNilForMissingFile() async {
        let cache = ThumbnailCache.shared
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).png")
        let result = await cache.loadImage(for: url)
        #expect(result == nil)
    }

    // MARK: - Thumbnail downsampling

    @Test func loadThumbnailDownsamples() async {
        let cache = ThumbnailCache.shared
        let (url, _) = createTestImage(size: NSSize(width: 500, height: 300))
        defer { try? FileManager.default.removeItem(at: url) }

        let fullImage = await cache.loadImage(for: url)!
        let fullPixels = max(fullImage.representations.first!.pixelsWide,
                             fullImage.representations.first!.pixelsHigh)

        let thumb = await cache.loadThumbnail(for: url, maxPixelSize: 100)!
        let thumbPixels = max(thumb.representations.first!.pixelsWide,
                              thumb.representations.first!.pixelsHigh)
        // Thumbnail must be strictly smaller than the original
        #expect(thumbPixels < fullPixels)
    }

    @Test func loadThumbnailCachesSeparatelyFromFullImage() async {
        let cache = ThumbnailCache.shared
        let (url, _) = createTestImage(size: NSSize(width: 200, height: 100))
        defer { try? FileManager.default.removeItem(at: url) }

        let full = await cache.loadImage(for: url)
        let thumb = await cache.loadThumbnail(for: url, maxPixelSize: 56)
        #expect(full != nil)
        #expect(thumb != nil)
        #expect(full !== thumb)
    }

    @Test func loadThumbnailReturnsNilForMissingFile() async {
        let cache = ThumbnailCache.shared
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).png")
        let result = await cache.loadThumbnail(for: url, maxPixelSize: 56)
        #expect(result == nil)
    }
}
