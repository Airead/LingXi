//
//  AnnotationStateTests.swift
//  LingXiTests
//

import SwiftUI
import Testing
@testable import LingXi

@Suite("AnnotationState")
@MainActor
struct AnnotationStateTests {

    private func makeState() -> AnnotationState {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        return AnnotationState(sourceImage: image)
    }

    private func makeItem(
        type: AnnotationType = .rectangle(CGRect(x: 0, y: 0, width: 50, height: 50))
    ) -> AnnotationItem {
        AnnotationItem(
            type: type,
            bounds: CGRect(x: 0, y: 0, width: 50, height: 50),
            properties: AnnotationProperties(
                strokeColor: .red,
                fillColor: .clear,
                strokeWidth: 3.0,
                fontSize: 14.0,
                fontName: "Helvetica"
            )
        )
    }

    // MARK: - Add / Delete

    @Test("addAnnotation appends item and saves undo state")
    func addAnnotation() {
        let state = makeState()
        let item = makeItem()

        state.addAnnotation(item)

        #expect(state.annotations.count == 1)
        #expect(state.annotations.first?.id == item.id)
        #expect(state.canUndo)
        #expect(!state.canRedo)
    }

    @Test("deleteSelected removes selected annotation")
    func deleteSelected() {
        let state = makeState()
        let item = makeItem()
        state.addAnnotation(item)
        state.selectedAnnotationId = item.id

        state.deleteSelected()

        #expect(state.annotations.isEmpty)
        #expect(state.selectedAnnotationId == nil)
    }

    @Test("deleteSelected does nothing when no selection")
    func deleteSelectedNoSelection() {
        let state = makeState()
        state.addAnnotation(makeItem())

        state.deleteSelected()

        #expect(state.annotations.count == 1)
    }

    @Test("deleteAnnotation removes by id")
    func deleteAnnotationById() {
        let state = makeState()
        let item1 = makeItem()
        let item2 = makeItem()
        state.addAnnotation(item1)
        state.addAnnotation(item2)

        state.deleteAnnotation(id: item1.id)

        #expect(state.annotations.count == 1)
        #expect(state.annotations.first?.id == item2.id)
    }

    @Test("deleteAnnotation clears selectedAnnotationId when deleting selected")
    func deleteAnnotationClearsSelection() {
        let state = makeState()
        let item = makeItem()
        state.addAnnotation(item)
        state.selectedAnnotationId = item.id

        state.deleteAnnotation(id: item.id)

        #expect(state.selectedAnnotationId == nil)
    }

    // MARK: - Undo / Redo

    @Test("undo restores previous state")
    func undoRestoresPrevious() {
        let state = makeState()
        let item = makeItem()
        state.addAnnotation(item)

        state.undo()

        #expect(state.annotations.isEmpty)
        #expect(!state.canUndo)
        #expect(state.canRedo)
    }

    @Test("redo restores undone state")
    func redoRestoresUndone() {
        let state = makeState()
        let item = makeItem()
        state.addAnnotation(item)
        state.undo()

        state.redo()

        #expect(state.annotations.count == 1)
        #expect(state.annotations.first?.id == item.id)
        #expect(state.canUndo)
        #expect(!state.canRedo)
    }

    @Test("undo/redo round-trip preserves annotations")
    func undoRedoRoundTrip() {
        let state = makeState()
        let item1 = makeItem()
        let item2 = makeItem()
        state.addAnnotation(item1)
        state.addAnnotation(item2)

        // Undo both
        state.undo()
        #expect(state.annotations.count == 1)
        state.undo()
        #expect(state.annotations.isEmpty)

        // Redo both
        state.redo()
        #expect(state.annotations.count == 1)
        state.redo()
        #expect(state.annotations.count == 2)
    }

    @Test("new action clears redo stack")
    func newActionClearsRedo() {
        let state = makeState()
        state.addAnnotation(makeItem())
        state.undo()
        #expect(state.canRedo)

        state.addAnnotation(makeItem())

        #expect(!state.canRedo)
    }

    @Test("undo on empty stack does nothing")
    func undoOnEmptyStack() {
        let state = makeState()
        state.undo()
        #expect(state.annotations.isEmpty)
    }

    @Test("redo on empty stack does nothing")
    func redoOnEmptyStack() {
        let state = makeState()
        state.redo()
        #expect(state.annotations.isEmpty)
    }

    // MARK: - Tool switching

    @Test("selectedTool defaults to arrow")
    func defaultTool() {
        let state = makeState()
        #expect(state.selectedTool == .arrow)
    }

    @Test("tool switching updates selectedTool")
    func toolSwitching() {
        let state = makeState()

        state.selectedTool = .rectangle
        #expect(state.selectedTool == .rectangle)

        state.selectedTool = .pencil
        #expect(state.selectedTool == .pencil)

        state.selectedTool = .text
        #expect(state.selectedTool == .text)
    }

    // MARK: - Counter auto-increment

    @Test("counter auto-increments on add")
    func counterAutoIncrement() {
        let state = makeState()
        #expect(state.nextCounterNumber == 1)

        let counter1 = makeItem(type: .counter(1))
        state.addAnnotation(counter1)
        #expect(state.nextCounterNumber == 2)

        let counter2 = makeItem(type: .counter(2))
        state.addAnnotation(counter2)
        #expect(state.nextCounterNumber == 3)
    }

    @Test("non-counter annotations do not increment counter")
    func nonCounterDoesNotIncrement() {
        let state = makeState()
        state.addAnnotation(makeItem(type: .rectangle(CGRect(x: 0, y: 0, width: 50, height: 50))))
        #expect(state.nextCounterNumber == 1)
    }

    // MARK: - Update annotation

    @Test("updateAnnotation modifies existing annotation")
    func updateAnnotation() {
        let state = makeState()
        let item = makeItem()
        state.addAnnotation(item)

        state.updateAnnotation(id: item.id) { annotation in
            annotation.bounds = CGRect(x: 10, y: 10, width: 100, height: 100)
        }

        #expect(state.annotations.first?.bounds == CGRect(x: 10, y: 10, width: 100, height: 100))
        // addAnnotation + updateAnnotation = 2 undo levels
        state.undo()
        #expect(state.annotations.count == 1)
        #expect(state.annotations.first?.bounds == CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    // MARK: - Crop

    @Test("applyCrop changes source image size and clears annotations")
    func applyCrop() {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        image.unlockFocus()
        let state = AnnotationState(sourceImage: image)
        state.addAnnotation(makeItem())

        state.applyCrop(rect: CGRect(x: 50, y: 50, width: 100, height: 100))

        #expect(state.annotations.isEmpty, "Crop should clear annotations")
        #expect(state.sourceImage.size.width == 100, "Cropped width should be 100")
        #expect(state.sourceImage.size.height == 100, "Cropped height should be 100")
        #expect(!state.canUndo, "Crop should clear undo stack")
        #expect(!state.canRedo, "Crop should clear redo stack")
    }

    // MARK: - AnnotationTool

    @Test("all tools have unique shortcut keys")
    func uniqueShortcutKeys() {
        let keys = AnnotationTool.allCases.map(\.shortcutKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test("all tools have non-empty icon and displayName")
    func toolPropertiesNonEmpty() {
        for tool in AnnotationTool.allCases {
            #expect(!tool.icon.isEmpty)
            #expect(!tool.displayName.isEmpty)
            #expect(tool.id == tool.rawValue)
        }
    }
}
