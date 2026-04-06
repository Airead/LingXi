//
//  RegionSelectionControllerTests.swift
//  LingXiTests
//

import AppKit
import Testing
@testable import LingXi

@Suite("RegionSelectionController")
struct RegionSelectionControllerTests {

    @MainActor
    private static func makeTestFixture(
        imageWidth: Int = 100,
        imageHeight: Int = 100
    ) -> (controller: RegionSelectionController, window: RegionSelectionWindow, image: CGImage, screenFrame: CGRect) {
        let controller = RegionSelectionController()
        let screen = NSScreen.screens[0]
        let window = RegionSelectionWindow(screen: screen)
        window.overlayView.delegate = controller
        let image = makeTestImage(width: imageWidth, height: imageHeight)
        return (controller, window, image, screen.frame)
    }

    @Test("cancelSelection returns nil")
    @MainActor
    func cancelReturnsNil() async {
        let fixture = Self.makeTestFixture()

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            fixture.controller.cancelSelection()
        }

        let result = await fixture.controller.awaitSelection(
            window: fixture.window, image: fixture.image, scaleFactor: 1.0, screenFrame: fixture.screenFrame
        )
        #expect(result == nil)
    }

    @Test("double awaitSelection cancels first and returns nil")
    @MainActor
    func doubleStartCancelsFirst() async {
        let fixture = Self.makeTestFixture()

        let firstTask = Task<SelectionResult?, Never> {
            await fixture.controller.awaitSelection(
                window: fixture.window, image: fixture.image, scaleFactor: 1.0, screenFrame: fixture.screenFrame
            )
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        let window2 = RegionSelectionWindow(screen: NSScreen.screens[0])
        window2.overlayView.delegate = fixture.controller
        let secondTask = Task<SelectionResult?, Never> {
            await fixture.controller.awaitSelection(
                window: window2, image: fixture.image, scaleFactor: 1.0, screenFrame: fixture.screenFrame
            )
        }

        let firstResult = await firstTask.value
        #expect(firstResult == nil)

        fixture.controller.cancelSelection()
        let secondResult = await secondTask.value
        #expect(secondResult == nil)
    }

    @Test("overlayDidSelectRegion returns correct result")
    @MainActor
    func selectRegionReturnsResult() async {
        let fixture = Self.makeTestFixture(imageWidth: 200, imageHeight: 200)
        let expectedRect = CGRect(x: 10, y: 20, width: 50, height: 30)

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            fixture.controller.overlayDidSelectRegion(expectedRect, from: fixture.window.overlayView)
        }

        let result = await fixture.controller.awaitSelection(
            window: fixture.window, image: fixture.image, scaleFactor: 2.0, screenFrame: fixture.screenFrame
        )

        #expect(result != nil)
        #expect(result?.region == expectedRect)
        #expect(result?.scaleFactor == 2.0)
        #expect(result?.image.width == 200)
        #expect(result?.screenFrame == fixture.screenFrame)
    }

    @Test("overlayDidCancel returns nil")
    @MainActor
    func cancelViaOverlayReturnsNil() async {
        let fixture = Self.makeTestFixture()

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            fixture.controller.overlayDidCancel(fixture.window.overlayView)
        }

        let result = await fixture.controller.awaitSelection(
            window: fixture.window, image: fixture.image, scaleFactor: 1.0, screenFrame: fixture.screenFrame
        )
        #expect(result == nil)
    }
}
