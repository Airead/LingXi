//
//  AnnotationWindowController.swift
//  LingXi
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AnnotationWindowController: NSWindowController {
    private static let minWindowWidth: CGFloat = 400
    private static let minWindowHeight: CGFloat = 300
    private static let maxScreenFraction: CGFloat = 0.8
    private static let fallbackScreenFrame = NSRect(x: 0, y: 0, width: 800, height: 600)

    let annotationState: AnnotationState
    private let onClose: (AnnotationWindowController) -> Void

    init(image: NSImage, onClose: @escaping (AnnotationWindowController) -> Void) {
        DebugLog.logMemory("AnnotationWindowController.init")
        let state = AnnotationState(sourceImage: image)
        self.annotationState = state
        self.onClose = onClose

        let imageSize = image.size
        let mouseLocation = NSEvent.mouseLocation
        let screenFrame = NSScreen.screens.first { $0.frame.contains(mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? Self.fallbackScreenFrame

        let maxWidth = screenFrame.width * Self.maxScreenFraction
        let maxHeight = screenFrame.height * Self.maxScreenFraction
        let scale = min(1.0, min(maxWidth / imageSize.width, maxHeight / imageSize.height))
        let windowWidth = max(Self.minWindowWidth, imageSize.width * scale)
        let windowHeight = max(Self.minWindowHeight, imageSize.height * scale)

        let contentRect = NSRect(
            x: screenFrame.midX - windowWidth / 2,
            y: screenFrame.midY - windowHeight / 2,
            width: windowWidth,
            height: windowHeight
        )

        let window = AnnotationWindow(contentRect: contentRect)
        window.minSize = NSSize(width: Self.minWindowWidth, height: Self.minWindowHeight)
        window.annotationState = state
        let editorView = AnnotationEditorView(state: state)
        window.contentView = NSHostingView(rootView: editorView)

        super.init(window: window)

        window.delegate = self

        state.onSave = { [weak self] in
            self?.saveImageAs()
        }
        state.onCopy = { [weak self] in
            self?.copyImage()
        }
        state.onClose = { [weak self] in
            self?.window?.close()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        DebugLog.logMemory("AnnotationWindowController.deinit")
    }

    // MARK: - Export actions

    private func copyImage() {
        guard let rendered = renderFinalImage() else { return }
        ImageExporter.copyToClipboard(rendered)
        DebugLog.log("[Screenshot] Image copied to clipboard")
        window?.close()
    }

    private func saveImageAs() {
        guard let win = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "Screenshot.png"
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveToURL(url)
        }
    }

    private func saveToURL(_ url: URL) {
        guard let rendered = renderFinalImage() else { return }
        let format: ImageFormat = UTType(filenameExtension: url.pathExtension) == .jpeg ? .jpeg : .png
        do {
            try ImageExporter.saveToFile(rendered, url: url, format: format)
            DebugLog.log("[Screenshot] Image saved to \(url.path)")
            window?.close()
        } catch {
            DebugLog.log("[Screenshot] Save failed: \(error)")
        }
    }

    private func renderFinalImage() -> CGImage? {
        let sourceImage = annotationState.sourceImage
        guard let cgImage = sourceImage.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return nil }
        return ImageExporter.renderFinalImage(
            source: cgImage,
            imagePointSize: sourceImage.size,
            annotations: annotationState.annotations,
            blurCacheManager: annotationState.blurCacheManager
        )
    }
}

// MARK: - NSWindowDelegate

extension AnnotationWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        DebugLog.logMemory("AnnotationWindowController.windowWillClose")
        onClose(self)
    }
}
