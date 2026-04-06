//
//  RegionSelectionWindow.swift
//  LingXi
//

import AppKit

final class RegionSelectionWindow: NSPanel {
    let overlayView = RegionSelectionOverlayView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        isMovable = false
        ignoresMouseEvents = false

        overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlayView.autoresizingMask = [.width, .height]
        contentView = overlayView
    }

    // Must be key window to receive keyDown events (Escape to cancel).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
