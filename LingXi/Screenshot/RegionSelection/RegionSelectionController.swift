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
@MainActor
final class RegionSelectionController {
    static let shared = RegionSelectionController()

    private var windowPool: [RegionSelectionWindow] = []
    private var activeWindows: [RegionSelectionWindow] = []
    private var windowCaptureInfo: [ObjectIdentifier: CaptureInfo] = [:]
    private var continuation: CheckedContinuation<SelectionResult?, Never>?

    private struct CaptureInfo {
        let image: CGImage
        let scaleFactor: CGFloat
        let screenFrame: CGRect
    }

    private var poolInitialized = false

    init() {}

    /// Start region selection on the given screens with pre-captured images.
    /// Returns the selection result, or nil if the user cancels.
    func startSelection(captures: [ScreenCapture], screens: [NSScreen]) async -> SelectionResult? {
        cancelSelection()
        ensurePoolInitialized()

        for capture in captures {
            let screen = screens[capture.screenIndex]
            let window = acquireWindow(for: screen)
            window.overlayView.delegate = self
            window.overlayView.setBackgroundImage(capture.image, scaleFactor: capture.scaleFactor)
            window.makeKeyAndOrderFront(nil)
            registerWindow(window, image: capture.image, scaleFactor: capture.scaleFactor, screenFrame: screen.frame)
        }

        return await suspendForSelection()
    }

    /// Await a selection on a specific window without showing it.
    func awaitSelection(window: RegionSelectionWindow, image: CGImage, scaleFactor: CGFloat, screenFrame: CGRect) async -> SelectionResult? {
        cancelSelection()
        registerWindow(window, image: image, scaleFactor: scaleFactor, screenFrame: screenFrame)
        return await suspendForSelection()
    }

    /// Cancel the current selection, causing startSelection to return nil.
    func cancelSelection() {
        finish(with: nil)
    }

    private func registerWindow(_ window: RegionSelectionWindow, image: CGImage, scaleFactor: CGFloat, screenFrame: CGRect) {
        activeWindows.append(window)
        windowCaptureInfo[ObjectIdentifier(window)] = CaptureInfo(
            image: image,
            scaleFactor: scaleFactor,
            screenFrame: screenFrame
        )
    }

    private func suspendForSelection() async -> SelectionResult? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    // MARK: - Window pool

    private func ensurePoolInitialized() {
        guard !poolInitialized else { return }
        poolInitialized = true
        rebuildWindowPool()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.rebuildWindowPool()
            }
        }
    }

    private func rebuildWindowPool() {
        for window in windowPool {
            window.overlayView.clearBackgroundImage()
            window.orderOut(nil)
        }
        windowPool = NSScreen.screens.map { RegionSelectionWindow(screen: $0) }
    }

    private func acquireWindow(for screen: NSScreen) -> RegionSelectionWindow {
        if let index = windowPool.firstIndex(where: { $0.frame == screen.frame }) {
            return windowPool.remove(at: index)
        }
        return RegionSelectionWindow(screen: screen)
    }

    private func returnWindows() {
        for window in activeWindows {
            window.overlayView.delegate = nil
            window.overlayView.clearBackgroundImage()
            window.overlayView.resetSelectionState()
            window.orderOut(nil)
            windowPool.append(window)
        }
        activeWindows.removeAll()
        windowCaptureInfo.removeAll()
    }

    // MARK: - Private

    private func finish(with result: SelectionResult?) {
        let pending = continuation
        continuation = nil
        returnWindows()
        pending?.resume(returning: result)
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
