import AppKit

nonisolated enum PreviewData: Sendable {
    case text(String)
    case image(path: URL, description: String)
}

nonisolated enum SearchResultType: Sendable {
    case application
    case file
    case command
    case bookmark
    case clipboard
}

nonisolated enum ActionModifier: Int, Hashable, Sendable {
    case command
    case option
    case control
}

nonisolated struct ModifierAction: Sendable {
    let subtitle: String
    let action: @MainActor @Sendable (SearchResult) -> Bool

    static let revealInFinder = ModifierAction(subtitle: "Reveal in Finder") { result in
        guard let url = result.url else { return false }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        return true
    }

    static let copyURL = ModifierAction(subtitle: "Copy URL") { result in
        guard let url = result.url else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        return true
    }

    static let defaultFileActions: [ActionModifier: ModifierAction] = [
        .command: .revealInFinder,
    ]
}

nonisolated struct SearchResult: Identifiable, Sendable {
    let id = UUID()
    let itemId: String
    let icon: NSImage?
    let name: String
    let subtitle: String
    let resultType: SearchResultType
    let url: URL?
    var score: Double
    var previewData: PreviewData?
    var modifierActions: [ActionModifier: ModifierAction] = [:]
    var openWithBundleId: String?
    var thumbnailURL: URL?

    private static let modifierPriority: [ActionModifier] = [.command, .option, .control]

    func resolveModifierAction(for modifiers: Set<ActionModifier>) -> ModifierAction? {
        for modifier in Self.modifierPriority where modifiers.contains(modifier) {
            if let action = modifierActions[modifier] {
                return action
            }
        }
        return nil
    }

    func displaySubtitle(for modifiers: Set<ActionModifier>) -> String {
        resolveModifierAction(for: modifiers)?.subtitle ?? subtitle
    }
}

extension Array where Element == SearchResult {
    func sortedAndTruncated(maxResults: Int) -> [SearchResult] {
        var sorted = self
        sorted.sort { $0.score > $1.score }
        if sorted.count > maxResults {
            return Array(sorted.prefix(maxResults))
        }
        return sorted
    }
}
