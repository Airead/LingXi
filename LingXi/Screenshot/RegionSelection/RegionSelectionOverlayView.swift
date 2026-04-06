//
//  RegionSelectionOverlayView.swift
//  LingXi
//

import AppKit
import Carbon.HIToolbox
import QuartzCore

/// Delegate for region selection overlay events.
protocol RegionSelectionOverlayDelegate: AnyObject {
    func overlayDidCancel(_ overlay: RegionSelectionOverlayView)
    func overlayDidSelectRegion(_ rect: CGRect, from overlay: RegionSelectionOverlayView)
}

/// Full-screen overlay view that renders a frozen screenshot background,
/// a dim layer, and a crosshair indicator following the mouse cursor.
final class RegionSelectionOverlayView: NSView {

    weak var delegate: RegionSelectionOverlayDelegate?

    // MARK: - CALayer structure

    private let backgroundImageLayer = CALayer()
    private let dimLayer = CALayer()
    private let dimMaskLayer = CAShapeLayer()
    private let selectionBorderLayer = CAShapeLayer()
    private let sizeIndicatorLayer = CATextLayer()
    private let crosshairLayer = CAShapeLayer()

    private static let dimAlpha: Float = 0.3
    private static let crosshairSize: CGFloat = 10
    private static let crosshairStrokeWidth: CGFloat = 1.5
    private static let selectionBorderWidth: CGFloat = 1.0
    private static let minimumSelectionSize: CGFloat = 5.0
    private static let sizeIndicatorPadding: CGFloat = 6.0
    private static let sizeIndicatorOffset: CGFloat = 4.0
    private static let sizeIndicatorFontSize: CGFloat = 12.0
    private static let sizeIndicatorFont = NSFont.monospacedDigitSystemFont(ofSize: sizeIndicatorFontSize, weight: .medium)
    private static let sizeIndicatorAttributes: [NSAttributedString.Key: Any] = [.font: sizeIndicatorFont]

    // MARK: - Selection state

    private var dragOrigin: CGPoint?
    private var selectionRect: CGRect = .zero
    private var scaleFactor: CGFloat = 1.0

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
        dimMaskLayer.fillRule = .evenOdd
        dimMaskLayer.fillColor = NSColor.white.cgColor
        dimMaskLayer.actions = Self.disabledActions
        dimLayer.mask = dimMaskLayer
        rootLayer.addSublayer(dimLayer)

        selectionBorderLayer.strokeColor = NSColor.white.cgColor
        selectionBorderLayer.fillColor = nil
        selectionBorderLayer.lineWidth = Self.selectionBorderWidth
        selectionBorderLayer.actions = Self.disabledActions
        selectionBorderLayer.isHidden = true
        rootLayer.addSublayer(selectionBorderLayer)

        sizeIndicatorLayer.fontSize = Self.sizeIndicatorFontSize
        sizeIndicatorLayer.font = Self.sizeIndicatorFont
        sizeIndicatorLayer.foregroundColor = NSColor.white.cgColor
        sizeIndicatorLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        sizeIndicatorLayer.cornerRadius = 4
        sizeIndicatorLayer.alignmentMode = .center
        sizeIndicatorLayer.actions = Self.disabledActions
        sizeIndicatorLayer.isHidden = true
        rootLayer.addSublayer(sizeIndicatorLayer)

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
        self.scaleFactor = scaleFactor
        backgroundImageLayer.contents = image
        backgroundImageLayer.contentsScale = scaleFactor
        sizeIndicatorLayer.contentsScale = scaleFactor
    }

    /// Release the background image to free memory.
    func clearBackgroundImage() {
        backgroundImageLayer.contents = nil
    }

    override func layout() {
        super.layout()
        backgroundImageLayer.frame = bounds
        dimLayer.frame = bounds
        dimMaskLayer.frame = bounds
        crosshairLayer.frame = bounds
        updateDimMask()
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        selectionRect = .zero
        crosshairLayer.isHidden = true
        selectionBorderLayer.isHidden = false
        updateSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        if selectionRect.width >= Self.minimumSelectionSize && selectionRect.height >= Self.minimumSelectionSize {
            delegate?.overlayDidSelectRegion(selectionRect, from: self)
        } else {
            resetSelection()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCrosshair(at: point)
    }

    override func mouseEntered(with event: NSEvent) {
        if dragOrigin == nil {
            crosshairLayer.isHidden = false
        }
        NSCursor.crosshair.set()
    }

    override func mouseExited(with event: NSEvent) {
        if dragOrigin == nil {
            crosshairLayer.isHidden = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.overlayDidCancel(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            delegate?.overlayDidCancel(self)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Selection rendering

    private func updateSelection() {
        selectionBorderLayer.path = CGPath(rect: selectionRect, transform: nil)
        updateDimMask()
        updateSizeIndicator()
    }

    private func resetSelection() {
        selectionRect = .zero
        selectionBorderLayer.path = nil
        selectionBorderLayer.isHidden = true
        sizeIndicatorLayer.isHidden = true
        crosshairLayer.isHidden = false
        updateDimMask()
    }

    private func updateDimMask() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if selectionRect.width > 0 && selectionRect.height > 0 {
            path.addRect(selectionRect)
        }
        dimMaskLayer.path = path
    }

    private func updateSizeIndicator() {
        let pixelW = Int(selectionRect.width * scaleFactor)
        let pixelH = Int(selectionRect.height * scaleFactor)
        guard pixelW > 0 && pixelH > 0 else {
            sizeIndicatorLayer.isHidden = true
            return
        }

        let text = "\(pixelW) × \(pixelH)"
        sizeIndicatorLayer.string = text

        let textSize = (text as NSString).size(withAttributes: Self.sizeIndicatorAttributes)
        let layerWidth = textSize.width + Self.sizeIndicatorPadding * 2
        let layerHeight = textSize.height + Self.sizeIndicatorPadding

        var x = selectionRect.maxX - layerWidth
        var y = selectionRect.minY - layerHeight - Self.sizeIndicatorOffset

        // Keep within view bounds
        if y < 0 {
            y = selectionRect.maxY + Self.sizeIndicatorOffset
        }
        if x < 0 {
            x = selectionRect.minX
        }

        sizeIndicatorLayer.frame = CGRect(x: x, y: y, width: layerWidth, height: layerHeight)
        sizeIndicatorLayer.isHidden = false
    }

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
