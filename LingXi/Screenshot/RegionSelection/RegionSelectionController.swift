//
//  RegionSelectionController.swift
//  LingXi
//

import AppKit

/// Input for region selection: a captured screen image with metadata.
struct ScreenCapture: @unchecked Sendable {
    let screenIndex: Int
    let image: CGImage
    let scaleFactor: CGFloat
}

/// Result of a successful region selection.
struct SelectionResult {
    let region: CGRect
    let image: CGImage
    let scaleFactor: CGFloat
    let screenFrame: CGRect
}

/// Coordinates the region selection flow across overlay windows.
/// Uses async/await via CheckedContinuation to wrap the delegate-based overlay.
@MainActor
final class RegionSelectionController {
    static let shared = RegionSelectionController()

    private var regionWindows: [RegionSelectionWindow] = []
    private var windowCaptureInfo: [ObjectIdentifier: CaptureInfo] = [:]
    private var continuation: CheckedContinuation<SelectionResult?, Never>?

    private struct CaptureInfo {
        let image: CGImage
        let scaleFactor: CGFloat
        let screenFrame: CGRect
    }

    private init() {}

    /// Start region selection on the given screens with pre-captured images.
    /// Returns the selection result, or nil if the user cancels.
    func startSelection(captures: [ScreenCapture], screens: [NSScreen]) async -> SelectionResult? {
        cancelSelection()

        for capture in captures {
            let screen = screens[capture.screenIndex]
            let window = RegionSelectionWindow(screen: screen)
            window.overlayView.delegate = self
            window.overlayView.setBackgroundImage(capture.image, scaleFactor: capture.scaleFactor)
            window.makeKeyAndOrderFront(nil)
            regionWindows.append(window)
            windowCaptureInfo[ObjectIdentifier(window)] = CaptureInfo(
                image: capture.image,
                scaleFactor: capture.scaleFactor,
                screenFrame: screen.frame
            )
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Cancel the current selection, causing startSelection to return nil.
    func cancelSelection() {
        finish(with: nil)
    }

    // MARK: - Private

    private func finish(with result: SelectionResult?) {
        let pending = continuation
        continuation = nil
        dismissAll()
        pending?.resume(returning: result)
    }

    private func dismissAll() {
        for window in regionWindows {
            window.overlayView.clearBackgroundImage()
            window.orderOut(nil)
        }
        regionWindows.removeAll()
        windowCaptureInfo.removeAll()
    }
}

// MARK: - RegionSelectionOverlayDelegate

extension RegionSelectionController: RegionSelectionOverlayDelegate {
    func overlayDidCancel(_ overlay: RegionSelectionOverlayView) {
        finish(with: nil)
    }

    func overlayDidSelectRegion(_ rect: CGRect, from overlay: RegionSelectionOverlayView) {
        guard let window = overlay.window as? RegionSelectionWindow,
              let info = windowCaptureInfo[ObjectIdentifier(window)] else {
            finish(with: nil)
            return
        }

        finish(with: SelectionResult(
            region: rect,
            image: info.image,
            scaleFactor: info.scaleFactor,
            screenFrame: info.screenFrame
        ))
    }
}
