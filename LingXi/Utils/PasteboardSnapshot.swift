//
//  PasteboardSnapshot.swift
//  LingXi
//

import AppKit

/// Captures the full contents of a pasteboard (every item, every type) so
/// the previous clipboard can be restored after a transient write, e.g. the
/// voice input's paste-via-⌘V.
nonisolated struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    var isEmpty: Bool { items.isEmpty }

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    /// Replaces the pasteboard contents with the captured items. An empty
    /// snapshot restores to an empty pasteboard.
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// Restores after `delay`, but only when the pasteboard's change count
    /// still equals `expected` — i.e. nothing else (the user copying, another
    /// app) wrote to it in the meantime.
    func restore(
        to pasteboard: NSPasteboard,
        after delay: Duration,
        ifChangeCountEquals expected: Int
    ) async {
        try? await Task.sleep(for: delay)
        guard pasteboard.changeCount == expected else { return }
        restore(to: pasteboard)
    }
}
