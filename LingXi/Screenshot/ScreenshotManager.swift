//
//  ScreenshotManager.swift
//  LingXi
//

import AppKit
import ScreenCaptureKit

@MainActor
final class ScreenshotManager {
    static let shared = ScreenshotManager()

    private let captureService = ScreenCaptureService.shared
    private let regionController = RegionSelectionController.shared
    private var annotationWindowControllers: [AnnotationWindowController] = []

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

        DebugLog.logMemory("showRegionSelection start")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            DebugLog.log("[ScreenshotManager] Failed to get shareable content: \(error)")
            return
        }

        let captures: [ScreenCapture] = await withTaskGroup(of: ScreenCapture?.self) { group in
            for info in screenInfos {
                group.addTask { await self.captureScreenImage(info: info, content: content) }
            }
            var results: [ScreenCapture] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        DebugLog.logMemory("captures done (count=\(captures.count))")

        guard let result = await regionController.startSelection(captures: captures, screens: screens) else {
            DebugLog.logMemory("region selection cancelled")
            return
        }

        DebugLog.logMemory("region selection done")

        let service = captureService
        let cropped = await Task.detached {
            service.cropImage(result.image, to: result.region, screenFrame: result.screenFrame, scaleFactor: result.scaleFactor)
        }.value

        guard let croppedImage = cropped else { return }

        DebugLog.logMemory("crop done (\(croppedImage.width)x\(croppedImage.height))")

        let nsImage = NSImage(cgImage: croppedImage, size: NSSize(
            width: CGFloat(croppedImage.width) / result.scaleFactor,
            height: CGFloat(croppedImage.height) / result.scaleFactor
        ))
        openAnnotationEditor(with: nsImage)
    }

    @concurrent
    private func captureScreenImage(info: ScreenInfo, content: SCShareableContent) async -> ScreenCapture? {
        do {
            let image = try await captureService.captureFullScreen(
                displayID: info.displayID,
                content: content,
                pixelWidth: info.pixelWidth,
                pixelHeight: info.pixelHeight
            )
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
            let content = try await SCShareableContent.current
            let cgImage = try await captureService.captureFullScreen(displayID: displayID, content: content)
            captureService.copyToClipboard(cgImage: cgImage)
        } catch {
            DebugLog.log("[ScreenshotManager] Capture failed: \(error)")
        }
    }

    // MARK: - Annotation editor

    private func openAnnotationEditor(with image: NSImage) {
        DebugLog.logMemory("openAnnotationEditor: image=\(Int(image.size.width))x\(Int(image.size.height)), controllers=\(annotationWindowControllers.count)")
        let controller = AnnotationWindowController(image: image) { [weak self] controller in
            self?.annotationWindowControllers.removeAll { $0 === controller }
            DebugLog.logMemory("onClose: controllers=\(self?.annotationWindowControllers.count ?? -1)")
        }
        annotationWindowControllers.append(controller)
        controller.showWindow()
    }

    // MARK: - Window management

    private func hideAppWindows() {
        for window in NSApp.windows where window is FloatingPanel && window.isVisible {
            window.orderOut(nil)
        }
    }

}

