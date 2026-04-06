//
//  ScreenshotManagerTests.swift
//  LingXiTests
//

import AppKit
import Testing
import UniformTypeIdentifiers
@testable import LingXi

@Suite("ScreenshotManager")
struct ScreenshotManagerTests {

    @Test("pngData produces valid PNG from CGImage")
    func pngDataFromImage() {
        let image = makeTestImage(width: 10, height: 10)

        let data = ScreenshotManager.pngData(from: image)
        #expect(data != nil)

        // Verify it's valid PNG by reading it back
        if let data {
            let provider = CGDataProvider(data: data as CFData)!
            let decoded = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
            #expect(decoded != nil)
            #expect(decoded?.width == 10)
            #expect(decoded?.height == 10)
        }
    }
}
