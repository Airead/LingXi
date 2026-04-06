//
//  AnnotationWindow.swift
//  LingXi
//

import AppKit

final class AnnotationWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        minSize = NSSize(width: 400, height: 300)
        animationBehavior = .documentWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
