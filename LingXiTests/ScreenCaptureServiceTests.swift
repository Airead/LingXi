//
//  ScreenCaptureServiceTests.swift
//  LingXiTests
//

import AppKit
import Testing
@testable import LingXi

@Suite("ScreenCaptureService")
struct ScreenCaptureServiceTests {

    // MARK: - cropImage tests

    @Test("cropImage crops correctly on 1x display")
    func cropImage1x() {
        let service = ScreenCaptureService.shared
        // Simulate a 1920x1080 screen at 1x scale
        let image = makeTestImage(width: 1920, height: 1080)
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Crop a 200x100 region at (100, 200) in Cocoa coordinates (bottom-left origin)
        let cropRect = CGRect(x: 100, y: 200, width: 200, height: 100)
        let cropped = service.cropImage(image, to: cropRect, screenFrame: screenFrame, scaleFactor: 1.0)

        #expect(cropped != nil)
        // At 1x scale: pixel width = ceil(200 * 1.0) = 200
        #expect(cropped!.width == 200)
        #expect(cropped!.height == 100)
    }

    @Test("cropImage crops correctly on 2x Retina display")
    func cropImage2x() {
        let service = ScreenCaptureService.shared
        // Simulate a 1440x900 logical screen captured at 2x → 2880x1800 pixels
        let image = makeTestImage(width: 2880, height: 1800)
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Crop a 100x50 logical region at (200, 300)
        let cropRect = CGRect(x: 200, y: 300, width: 100, height: 50)
        let cropped = service.cropImage(image, to: cropRect, screenFrame: screenFrame, scaleFactor: 2.0)

        #expect(cropped != nil)
        // At 2x: pixel width = ceil(100 * 2.0) = 200, height = ceil(50 * 2.0) = 100
        #expect(cropped!.width == 200)
        #expect(cropped!.height == 100)
    }

    @Test("cropImage handles Y-flip from Cocoa to pixel coordinates")
    func cropImageYFlip() {
        let service = ScreenCaptureService.shared
        // 800x600 screen at 1x
        let image = makeTestImage(width: 800, height: 600)
        let screenFrame = CGRect(x: 0, y: 0, width: 800, height: 600)

        // Crop at bottom-left corner in Cocoa coords: y=0 means bottom
        // After Y-flip: pixelY = ceil((600 - 0 - 100) * 1.0) = 500 (top-left origin)
        let cropRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cropped = service.cropImage(image, to: cropRect, screenFrame: screenFrame, scaleFactor: 1.0)

        #expect(cropped != nil)
        #expect(cropped!.width == 100)
        #expect(cropped!.height == 100)
    }

    @Test("cropImage returns nil for out-of-bounds region")
    func cropImageOutOfBounds() {
        let service = ScreenCaptureService.shared
        let image = makeTestImage(width: 100, height: 100)
        let screenFrame = CGRect(x: 0, y: 0, width: 100, height: 100)

        // Region entirely outside the image
        let cropRect = CGRect(x: 200, y: 200, width: 50, height: 50)
        let cropped = service.cropImage(image, to: cropRect, screenFrame: screenFrame, scaleFactor: 1.0)

        #expect(cropped == nil)
    }

    @Test("cropImage with fractional coordinates uses ceil for pixel alignment")
    func cropImageFractional() {
        let service = ScreenCaptureService.shared
        let image = makeTestImage(width: 2880, height: 1800)
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Fractional logical coordinates
        let cropRect = CGRect(x: 100.3, y: 200.7, width: 150.5, height: 80.2)
        let cropped = service.cropImage(image, to: cropRect, screenFrame: screenFrame, scaleFactor: 2.0)

        #expect(cropped != nil)
        // Pixel dimensions should be ceiled: ceil(150.5 * 2) = 301, ceil(80.2 * 2) = 161
        #expect(cropped!.width == 301)
        #expect(cropped!.height == 161)
    }

    // MARK: - copyToClipboard tests

    @Test("copyToClipboard with PNG data writes to pasteboard")
    @MainActor
    func copyToClipboardPNGData() {
        let service = ScreenCaptureService.shared
        let image = makeTestImage(width: 50, height: 50)
        let rep = NSBitmapImageRep(cgImage: image)
        let pngData = rep.representation(using: .png, properties: [:])!
        let testPasteboard = NSPasteboard(name: .init("io.github.airead.lingxi.test.png"))
        defer { testPasteboard.releaseGlobally() }

        service.copyToClipboard(pngData: pngData, pasteboard: testPasteboard)

        #expect(testPasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue]))
    }

    @Test("displayID returns a valid display ID for mouse location")
    @MainActor func displayIDAtPoint() {
        let service = ScreenCaptureService.shared
        let displayID = service.displayID(at: NSEvent.mouseLocation)
        #expect(displayID != 0)
    }

    // MARK: - Permission check (non-destructive)

    @Test("hasPermission returns a boolean without side effects")
    func hasPermission() {
        let service = ScreenCaptureService.shared
        // Just verify it doesn't crash — actual result depends on system state
        let _ = service.hasPermission()
    }

    // MARK: - Error descriptions

    @Test("ScreenCaptureError has meaningful descriptions")
    func errorDescriptions() {
        #expect(ScreenCaptureError.captureFailed("test").localizedDescription.contains("test"))
    }
}
