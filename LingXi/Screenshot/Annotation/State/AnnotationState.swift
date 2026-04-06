//
//  AnnotationState.swift
//  LingXi
//

import AppKit
import SwiftUI

@MainActor
@Observable
class AnnotationState {
    // MARK: - Image

    var sourceImage: NSImage
    var editedImage: NSImage?

    // MARK: - Tool

    var selectedTool: AnnotationTool = .arrow
    var strokeColor: Color = .red
    var fillColor: Color = .clear
    var strokeWidth: CGFloat = 3.0
    var fontSize: CGFloat = 16.0
    var blurType: BlurType = .pixelate

    // MARK: - Annotations

    var annotations: [AnnotationItem] = []
    var selectedAnnotationId: UUID?
    var selectedAnnotation: AnnotationItem? {
        selectedAnnotationId.flatMap { id in annotations.first { $0.id == id } }
    }
    var editingTextAnnotationId: UUID?

    // MARK: - Undo / Redo (snapshot-based)

    private static let maxUndoLevels = 50

    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []

    // MARK: - Drawing state

    var isDrawing: Bool = false
    var currentPoints: [CGPoint] = []
    var drawingStartPoint: CGPoint?
    var drawingEndPoint: CGPoint?

    // MARK: - Counter

    private(set) var nextCounterNumber: Int = 1

    // MARK: - Actions (bridged to window controller)

    @ObservationIgnored var onSave: (() -> Void)?
    @ObservationIgnored var onCopy: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onCancelTextEditing: (() -> Void)?

    // MARK: - Shared services

    @ObservationIgnored let blurCacheManager = BlurCacheManager()

    // MARK: - Zoom & Pan

    var zoomLevel: CGFloat = 1.0
    var panOffset: CGSize = .zero

    // MARK: - Init

    init(sourceImage: NSImage) {
        DebugLog.log("[Memory] AnnotationState.init: image=\(Int(sourceImage.size.width))x\(Int(sourceImage.size.height))")
        self.sourceImage = sourceImage
    }

    deinit {
        DebugLog.log("[Memory] AnnotationState.deinit")
    }

    // MARK: - Undo / Redo

    private func saveState() {
        undoStack.append(annotations)
        if undoStack.count > Self.maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Annotation operations

    func addAnnotation(_ item: AnnotationItem) {
        saveState()
        annotations.append(item)
        if case .counter = item.type {
            nextCounterNumber += 1
        }
    }

    func deleteSelected() {
        guard let selectedId = selectedAnnotationId,
              let index = annotations.firstIndex(where: { $0.id == selectedId }) else { return }
        saveState()
        annotations.remove(at: index)
        selectedAnnotationId = nil
    }

    func deleteAnnotation(id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        saveState()
        annotations.remove(at: index)
        if selectedAnnotationId == id {
            selectedAnnotationId = nil
        }
    }

    func updateAnnotation(id: UUID, update: (inout AnnotationItem) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        saveState()
        update(&annotations[index])
    }

    // MARK: - Drag operations (single undo snapshot per drag)

    func beginDrag() {
        saveState()
    }

    /// Update annotation during an active drag without creating a new undo snapshot.
    /// Caller must call `beginDrag()` first to capture the pre-drag state.
    func updateDragging(at index: Int, update: (inout AnnotationItem) -> Void) {
        guard annotations.indices.contains(index) else { return }
        update(&annotations[index])
    }

    // MARK: - Crop

    func applyCrop(rect: CGRect) {
        guard let cgImage = sourceImage.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return }

        let cgRect = rect.verticallyFlipped(
            imageHeight: CGFloat(cgImage.height)
        ).integral

        guard let cropped = cgImage.cropping(to: cgRect),
              let independent = Self.copyImageData(cropped) else { return }

        sourceImage = NSImage(
            cgImage: independent,
            size: NSSize(width: independent.width, height: independent.height)
        )
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        selectedAnnotationId = nil
    }

    /// Copy pixel data into a new independent CGImage so the original backing store can be freed.
    private nonisolated static func copyImageData(_ source: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: source.width,
            height: source.height,
            bitsPerComponent: source.bitsPerComponent,
            bytesPerRow: 0,
            space: source.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: source.bitmapInfo.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage()
    }
}
