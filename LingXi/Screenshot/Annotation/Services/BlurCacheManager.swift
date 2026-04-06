//
//  BlurCacheManager.swift
//  LingXi
//

import CoreImage
import CoreImage.CIFilterBuiltins

nonisolated final class BlurCacheManager {
    private struct CacheKey: Hashable {
        let rect: CGRect
        let blurType: BlurType
    }

    private var cache: [CacheKey: CGImage] = [:]
    private var insertionOrder: [CacheKey] = []
    private static let maxCacheSize = 16
    private lazy var ciContext = CIContext()
    private lazy var pixellateFilter = CIFilter.pixellate()
    private lazy var gaussianFilter = CIFilter.gaussianBlur()

    init() {
        DebugLog.log("[Memory] BlurCacheManager.init")
    }

    deinit {
        DebugLog.log("[Memory] BlurCacheManager.deinit, cacheSize=\(cache.count)")
    }

    func blurredImage(
        source: CGImage,
        rect: CGRect,
        blurType: BlurType
    ) -> CGImage? {
        // .integral is required for cache key stability (CGRect hashes bitwise)
        let clampedRect = rect.intersection(
            CGRect(x: 0, y: 0, width: source.width, height: source.height)
        ).integral
        guard clampedRect.width > 0, clampedRect.height > 0 else { return nil }

        let key = CacheKey(rect: clampedRect, blurType: blurType)
        if let cached = cache[key] {
            return cached
        }

        let result = applyBlur(to: source, rect: clampedRect, blurType: blurType)
        if let result {
            if cache.count >= Self.maxCacheSize {
                let oldest = insertionOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            cache[key] = result
            insertionOrder.append(key)
        }
        return result
    }

    func clearCache() {
        cache.removeAll()
        insertionOrder.removeAll()
    }

    private func applyBlur(to source: CGImage, rect: CGRect, blurType: BlurType) -> CGImage? {
        guard let cropped = source.cropping(to: rect) else { return nil }
        let ciImage = CIImage(cgImage: cropped)

        let output: CIImage?
        switch blurType {
        case .pixelate:
            let scale = max(4, max(rect.width, rect.height) / 20)
            pixellateFilter.inputImage = ciImage
            pixellateFilter.scale = Float(scale)
            pixellateFilter.center = CGPoint(x: rect.width / 2, y: rect.height / 2)
            output = pixellateFilter.outputImage
            pixellateFilter.inputImage = nil
        case .gaussian:
            gaussianFilter.inputImage = ciImage
            gaussianFilter.radius = 10.0
            output = gaussianFilter.outputImage
            gaussianFilter.inputImage = nil
        }

        guard let output else { return nil }
        let clamped = output.cropped(to: ciImage.extent)
        return ciContext.createCGImage(clamped, from: ciImage.extent)
    }
}
