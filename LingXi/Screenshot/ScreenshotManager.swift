//
//  ScreenshotManager.swift
//  LingXi
//

import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotManager {
    static let shared = ScreenshotManager()

    private let captureService = ScreenCaptureService.shared
    private var regionWindows: [RegionSelectionWindow] = []
    private var windowCaptureInfo: [ObjectIdentifier: CaptureInfo] = [:]

    private struct CaptureInfo {
        let image: CGImage
        let scaleFactor: CGFloat
        let screenFrame: CGRect
    }

    private init() {}

    func captureRegion() async {
        guard ensurePermission() else { return }
        await showRegionSelection()
    }

    // MARK: - Region selection

    private struct ScreenInfo: Sendable {
        let index: Int
        let displayID: CGDirectDisplayID
        let scale: CGFloat
        let pixelWidth: UInt32
        let pixelHeight: UInt32
    }

    private struct CaptureResult: @unchecked Sendable {
        let screenIndex: Int
        let image: CGImage
        let scaleFactor: CGFloat
    }

    private func showRegionSelection() async {
        dismissRegionSelection()

        let screens = NSScreen.screens

        let screenInfos: [ScreenInfo] = screens.enumerated().map { index, screen in
            let scale = screen.backingScaleFactor
            return ScreenInfo(
                index: index,
                displayID: captureService.displayID(for: screen),
                scale: scale,
                pixelWidth: UInt32(screen.frame.width * scale),
                pixelHeight: UInt32(screen.frame.height * scale)
            )
        }

        let captures: [CaptureResult] = await withTaskGroup(of: CaptureResult?.self) { group in
            for info in screenInfos {
                group.addTask { await self.captureScreenImage(info: info) }
            }
            var results: [CaptureResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

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
    }

    private func dismissRegionSelection() {
        for window in regionWindows {
            window.overlayView.clearBackgroundImage()
            window.orderOut(nil)
        }
        regionWindows.removeAll()
        windowCaptureInfo.removeAll()
    }

    @concurrent
    private func captureScreenImage(info: ScreenInfo) async -> CaptureResult? {
        do {
            let pngData = try await captureService.captureFullScreen(
                displayID: info.displayID,
                pixelWidth: info.pixelWidth,
                pixelHeight: info.pixelHeight
            )
            guard let provider = CGDataProvider(data: pngData as CFData),
                  let image = CGImage(
                      pngDataProviderSource: provider,
                      decode: nil,
                      shouldInterpolate: false,
                      intent: .defaultIntent
                  ) else { return nil }
            return CaptureResult(screenIndex: info.index, image: image, scaleFactor: info.scale)
        } catch {
            await DebugLog.log("[ScreenshotManager] Background capture failed: \(error)")
            return nil
        }
    }

    func captureFullScreen() async {
        await captureAndCopy()
    }

    private func ensurePermission() -> Bool {
        guard captureService.requestPermission() else {
            DebugLog.log("[ScreenshotManager] Screen recording permission denied")
            return false
        }
        return true
    }

    private func captureAndCopy() async {
        guard ensurePermission() else { return }

        let displayID = captureService.displayID(at: NSEvent.mouseLocation)

        do {
            let pngData = try await captureService.captureFullScreen(displayID: displayID)
            captureService.copyToClipboard(pngData: pngData)
        } catch {
            DebugLog.log("[ScreenshotManager] Capture failed: \(error)")
        }
    }

    // MARK: - Image conversion

    nonisolated private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// MARK: - RegionSelectionOverlayDelegate

extension ScreenshotManager: RegionSelectionOverlayDelegate {
    func overlayDidCancel(_ overlay: RegionSelectionOverlayView) {
        dismissRegionSelection()
    }

    func overlayDidSelectRegion(_ rect: CGRect, from overlay: RegionSelectionOverlayView) {
        guard let window = overlay.window as? RegionSelectionWindow,
              let info = windowCaptureInfo[ObjectIdentifier(window)] else {
            dismissRegionSelection()
            return
        }

        let service = captureService
        dismissRegionSelection()

        Task.detached {
            if let cropped = service.cropImage(info.image, to: rect, screenFrame: info.screenFrame, scaleFactor: info.scaleFactor),
               let pngData = ScreenshotManager.pngData(from: cropped) {
                await MainActor.run {
                    service.copyToClipboard(pngData: pngData)
                }
            }
        }
    }
}
