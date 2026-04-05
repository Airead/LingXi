import AppKit
import ImageIO

/// Shared cache for lazily loaded image thumbnails.
/// Uses NSCache for automatic memory eviction under pressure.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 50
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func loadImage(for url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        return await coalesce(key: key) {
            NSImage(contentsOf: url)
        }
    }

    /// Load a downsampled thumbnail. Uses a separate cache key to avoid
    /// conflicting with full-resolution entries.
    func loadThumbnail(for url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = "\(url.absoluteString)#thumb\(maxPixelSize)"
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let size = maxPixelSize
        return await coalesce(key: key) {
            Self.downsample(url: url, maxPixelSize: size)
        }
    }

    /// Coalesce concurrent loads for the same cache key into a single Task.
    private func coalesce(key: String, load: @Sendable @escaping () -> NSImage?) async -> NSImage? {
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task.detached {
            load()
        }
        inFlight[key] = task

        let image = await task.value
        inFlight.removeValue(forKey: key)
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }

    private nonisolated static func downsample(url: URL, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
