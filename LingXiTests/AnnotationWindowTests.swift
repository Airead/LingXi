//
//  AnnotationWindowTests.swift
//  LingXiTests
//

import AppKit
import Testing
@testable import LingXi

@Suite("AnnotationWindow")
@MainActor
struct AnnotationWindowTests {

    private func makeTestImage(width: Int = 200, height: Int = 100) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    @Test("AnnotationWindow has correct style")
    func windowStyle() {
        let window = AnnotationWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.canBecomeKey)
        #expect(window.canBecomeMain)
        // minSize is set by AnnotationWindowController, not the window itself
    }

    @Test("AnnotationWindowController initializes state with source image")
    func controllerInitializesState() {
        let image = makeTestImage()
        let controller = AnnotationWindowController(image: image) { _ in }

        #expect(controller.annotationState.sourceImage === image)
        #expect(controller.annotationState.annotations.isEmpty)
        #expect(controller.annotationState.selectedTool == .arrow)
        #expect(controller.window != nil)
        #expect(controller.window is AnnotationWindow)
    }

    @Test("AnnotationWindowController sizes window within screen bounds")
    func controllerWindowSize() {
        let image = makeTestImage(width: 200, height: 100)
        let controller = AnnotationWindowController(image: image) { _ in }

        guard let window = controller.window else {
            Issue.record("Window should not be nil")
            return
        }

        // Window should be at least the minimum size
        #expect(window.frame.width >= 400)
        #expect(window.frame.height >= 300)
    }

    @Test("AnnotationWindowController handles large image by scaling down")
    func controllerHandlesLargeImage() {
        let image = makeTestImage(width: 10000, height: 8000)
        let controller = AnnotationWindowController(image: image) { _ in }

        guard let window = controller.window,
              let screen = NSScreen.main else {
            Issue.record("Window and screen should not be nil")
            return
        }

        // Window should not exceed 80% of screen
        let maxWidth = screen.visibleFrame.width * 0.8
        let maxHeight = screen.visibleFrame.height * 0.8
        #expect(window.frame.width <= maxWidth + 1) // +1 for rounding
        #expect(window.frame.height <= maxHeight + 1)
    }
}
