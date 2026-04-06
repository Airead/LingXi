//
//  ScreenshotManager.swift
//  LingXi
//

import AppKit

/// Coordinates the screenshot workflow: capture, region selection, and output.
@MainActor
final class ScreenshotManager {
    static let shared = ScreenshotManager()

    private let captureService = ScreenCaptureService.shared

    private init() {}

    /// Capture a region screenshot.
    func captureRegion() async {
        await captureAndCopy()
    }

    /// Capture full screen screenshot and copy to clipboard.
    func captureFullScreen() async {
        await captureAndCopy()
    }

    private func captureAndCopy() async {
        guard captureService.requestPermission() else {
            DebugLog.log("[ScreenshotManager] Screen recording permission denied")
            return
        }

        let displayID = captureService.displayID(at: NSEvent.mouseLocation)

        do {
            let pngData = try await captureService.captureFullScreen(displayID: displayID)
            captureService.copyToClipboard(pngData: pngData)
        } catch {
            DebugLog.log("[ScreenshotManager] Capture failed: \(error)")
        }
    }
}
