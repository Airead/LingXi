import AppKit

enum SearchResultType: Sendable {
    case application
    case file
    case command
    case bookmark
}

enum ActionModifier: Int, Hashable, Sendable {
    case command
    case option
    case control
}

struct ModifierAction: Sendable {
    let subtitle: String
    let action: @MainActor @Sendable (SearchResult) -> Bool
}

struct SearchResult: Identifiable, Sendable {
    let id = UUID()
    let itemId: String
    let icon: NSImage?
    let name: String
    let subtitle: String
    let resultType: SearchResultType
    let url: URL?
    var score: Double
    var modifierActions: [ActionModifier: ModifierAction] = [:]

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
