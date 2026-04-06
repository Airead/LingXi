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
    private let regionController = RegionSelectionController.shared

    private init() {}

    func captureRegion() async {
        guard ensurePermission() else { return }
        hideAppWindows()
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

    private func showRegionSelection() async {
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

        let captures: [ScreenCapture] = await withTaskGroup(of: ScreenCapture?.self) { group in
            for info in screenInfos {
                group.addTask { await self.captureScreenImage(info: info) }
            }
            var results: [ScreenCapture] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        guard let result = await regionController.startSelection(captures: captures, screens: screens) else {
            return
        }

        let service = captureService
        Task.detached {
            if let cropped = service.cropImage(result.image, to: result.region, screenFrame: result.screenFrame, scaleFactor: result.scaleFactor),
               let pngData = ScreenshotManager.pngData(from: cropped) {
                await MainActor.run {
                    service.copyToClipboard(pngData: pngData)
                }
            }
        }
    }

    @concurrent
    private func captureScreenImage(info: ScreenInfo) async -> ScreenCapture? {
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
            return ScreenCapture(screenIndex: info.index, image: image, scaleFactor: info.scale)
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
        hideAppWindows()

        let displayID = captureService.displayID(at: NSEvent.mouseLocation)

        do {
            let pngData = try await captureService.captureFullScreen(displayID: displayID)
            captureService.copyToClipboard(pngData: pngData)
        } catch {
            DebugLog.log("[ScreenshotManager] Capture failed: \(error)")
        }
    }

    // MARK: - Window management

    private func hideAppWindows() {
        for window in NSApp.windows where window is FloatingPanel && window.isVisible {
            window.orderOut(nil)
        }
    }

    // MARK: - Image conversion

    nonisolated static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

