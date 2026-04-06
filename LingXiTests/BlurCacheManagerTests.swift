//
//  BlurCacheManagerTests.swift
//  LingXiTests
//

import AppKit
import Testing
@testable import LingXi

@Suite("BlurCacheManager")
struct BlurCacheManagerTests {

    private func makeTestImage(width: Int = 100, height: Int = 100) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Fill with a checkerboard pattern for visible blur effect
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 50, width: 50, height: 50))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 50, height: 50))
        return context.makeImage()!
    }

    @Test("produces pixelated image for valid rect")
    func pixelateBlur() {
        let manager = BlurCacheManager()
        let source = makeTestImage()
        let result = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurType: .pixelate
        )
        #expect(result != nil, "Pixelate should produce an image")
        #expect(result!.width > 0)
        #expect(result!.height > 0)
    }

    @Test("produces gaussian blurred image for valid rect")
    func gaussianBlur() {
        let manager = BlurCacheManager()
        let source = makeTestImage()
        let result = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurType: .gaussian
        )
        #expect(result != nil, "Gaussian blur should produce an image")
    }

    @Test("returns nil for zero-size rect")
    func zeroSizeRect() {
        let manager = BlurCacheManager()
        let source = makeTestImage()
        let result = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 0, height: 0),
            blurType: .pixelate
        )
        #expect(result == nil)
    }

    @Test("returns nil for rect outside image bounds")
    func outOfBoundsRect() {
        let manager = BlurCacheManager()
        let source = makeTestImage()
        let result = manager.blurredImage(
            source: source,
            rect: CGRect(x: 200, y: 200, width: 50, height: 50),
            blurType: .pixelate
        )
        #expect(result == nil)
    }

    @Test("reuses cache for same rect")
    func cacheReuse() {
        let manager = BlurCacheManager()
        let source = makeTestImage()

        let first = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurType: .pixelate
        )
        let second = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurType: .pixelate
        )
        #expect(first != nil)
        #expect(second != nil)
        #expect(first === second, "Should reuse cached image for same rect")
    }

    @Test("does not reuse cache for different blur type")
    func differentBlurType() {
        let manager = BlurCacheManager()
        let source = makeTestImage()

        let pixelate = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurType: .pixelate
        )
        let gaussian = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurType: .gaussian
        )
        #expect(pixelate != nil)
        #expect(gaussian != nil)
        #expect(pixelate !== gaussian, "Different blur types should not share cache")
    }

    @Test("caches multiple blur rects simultaneously")
    func multiRectCache() {
        let manager = BlurCacheManager()
        let source = makeTestImage()

        let rect1 = CGRect(x: 10, y: 10, width: 30, height: 30)
        let rect2 = CGRect(x: 50, y: 50, width: 30, height: 30)

        let first1 = manager.blurredImage(source: source, rect: rect1, blurType: .pixelate)
        let first2 = manager.blurredImage(source: source, rect: rect2, blurType: .pixelate)
        let second1 = manager.blurredImage(source: source, rect: rect1, blurType: .pixelate)

        #expect(first1 != nil)
        #expect(first2 != nil)
        #expect(first1 === second1, "Second call for rect1 should hit cache")
    }

    @Test("clearCache removes cached image")
    func clearCache() {
        let manager = BlurCacheManager()
        let source = makeTestImage()

        let first = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurType: .pixelate
        )
        manager.clearCache()
        let second = manager.blurredImage(
            source: source,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurType: .pixelate
        )
        #expect(first != nil)
        #expect(second != nil)
        #expect(first !== second, "After clearCache, should not reuse old result")
    }
}
