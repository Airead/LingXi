//
//  RegionSelectionOverlayView.swift
//  LingXi
//

import AppKit
import Carbon.HIToolbox
import QuartzCore

/// Delegate for region selection overlay events.
protocol RegionSelectionOverlayDelegate: AnyObject {
    func overlayDidCancel()
}

/// Full-screen overlay view that renders a frozen screenshot background,
/// a dim layer, and a crosshair indicator following the mouse cursor.
final class RegionSelectionOverlayView: NSView {

    weak var delegate: RegionSelectionOverlayDelegate?

    // MARK: - CALayer structure

    private let backgroundImageLayer = CALayer()
    private let dimLayer = CALayer()
    private let crosshairLayer = CAShapeLayer()

    private static let dimAlpha: Float = 0.3
    private static let crosshairSize: CGFloat = 10
    private static let crosshairStrokeWidth: CGFloat = 1.5

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layer setup

    override var wantsUpdateLayer: Bool { true }

    private func setupLayers() {
        wantsLayer = true
        guard let rootLayer = layer else { return }
        rootLayer.masksToBounds = true

        backgroundImageLayer.contentsGravity = .resize
        backgroundImageLayer.actions = Self.disabledActions
        rootLayer.addSublayer(backgroundImageLayer)

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = Self.dimAlpha
        dimLayer.actions = Self.disabledActions
        rootLayer.addSublayer(dimLayer)

        crosshairLayer.strokeColor = NSColor.white.cgColor
        crosshairLayer.fillColor = nil
        crosshairLayer.lineWidth = Self.crosshairStrokeWidth
        crosshairLayer.lineCap = .round
        crosshairLayer.shadowColor = NSColor.black.cgColor
        crosshairLayer.shadowOffset = .zero
        crosshairLayer.shadowRadius = 2
        crosshairLayer.shadowOpacity = 0.5
        crosshairLayer.actions = Self.disabledActions
        crosshairLayer.isHidden = true
        rootLayer.addSublayer(crosshairLayer)

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    /// Set the frozen screenshot to display as background.
    func setBackgroundImage(_ image: CGImage, scaleFactor: CGFloat) {
        backgroundImageLayer.contents = image
        backgroundImageLayer.contentsScale = scaleFactor
    }

    /// Release the background image to free memory.
    func clearBackgroundImage() {
        backgroundImageLayer.contents = nil
    }

    override func layout() {
        super.layout()
        backgroundImageLayer.frame = bounds
        dimLayer.frame = bounds
        crosshairLayer.frame = bounds
    }

    // MARK: - Mouse events

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCrosshair(at: point)
    }

    override func mouseEntered(with event: NSEvent) {
        crosshairLayer.isHidden = false
        NSCursor.crosshair.set()
    }

    override func mouseExited(with event: NSEvent) {
        crosshairLayer.isHidden = true
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.overlayDidCancel()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            delegate?.overlayDidCancel()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Crosshair rendering

    private func updateCrosshair(at point: CGPoint) {
        let s = Self.crosshairSize

        let path = CGMutablePath()
        // Horizontal line
        path.move(to: CGPoint(x: point.x - s, y: point.y))
        path.addLine(to: CGPoint(x: point.x + s, y: point.y))
        // Vertical line
        path.move(to: CGPoint(x: point.x, y: point.y - s))
        path.addLine(to: CGPoint(x: point.x, y: point.y + s))

        crosshairLayer.path = path
    }

    // MARK: - Helpers

    private static let disabledActions: [String: CAAction] = {
        let keys = ["position", "bounds", "path", "hidden", "opacity", "backgroundColor"]
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, NSNull() as CAAction) })
    }()
}
