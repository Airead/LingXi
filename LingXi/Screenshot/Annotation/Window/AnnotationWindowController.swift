//
//  AnnotationWindowController.swift
//  LingXi
//

import AppKit
import SwiftUI

@MainActor
final class AnnotationWindowController: NSWindowController {
    private static let minWindowWidth: CGFloat = 400
    private static let minWindowHeight: CGFloat = 300
    private static let maxScreenFraction: CGFloat = 0.8
    private static let fallbackScreenFrame = NSRect(x: 0, y: 0, width: 800, height: 600)

    let annotationState: AnnotationState
    private let onClose: (AnnotationWindowController) -> Void

    init(image: NSImage, onClose: @escaping (AnnotationWindowController) -> Void) {
        DebugLog.log("[Memory] AnnotationWindowController.init")
        let state = AnnotationState(sourceImage: image)
        self.annotationState = state
        self.onClose = onClose

        let imageSize = image.size
        let screenFrame = NSScreen.main?.visibleFrame ?? Self.fallbackScreenFrame

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
        let editorView = AnnotationEditorView(state: state)
        window.contentView = NSHostingView(rootView: editorView)

        super.init(window: window)

        window.delegate = self
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
        DebugLog.log("[Memory] AnnotationWindowController.deinit")
    }
}

// MARK: - NSWindowDelegate

extension AnnotationWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        DebugLog.log("[Memory] AnnotationWindowController.windowWillClose")
        onClose(self)
    }
}
