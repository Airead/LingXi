import AppKit

nonisolated enum CommandError: Error, CustomStringConvertible {
    case invalidName(String)

    var description: String {
        switch self {
        case .invalidName(let name):
            "Invalid command name \(name): must start with alphanumeric, contain only alphanumeric, hyphens, underscores, or colons."
        }
    }
}

struct CommandEntry: @unchecked Sendable {
    let name: String
    let title: String
    var subtitle: String = ""
    var icon: NSImage?
    let action: @MainActor @Sendable (String) async -> Void
    var promoted: Bool = false
}

actor CommandSearchProvider: SearchProvider {
    nonisolated static let itemIdPrefix = "cmd:"

    nonisolated static func extractName(from itemId: String) -> String? {
        guard itemId.hasPrefix(itemIdPrefix) else { return nil }
        return String(itemId.dropFirst(itemIdPrefix.count))
    }

    nonisolated private static let validNameRegex = /^[a-zA-Z0-9][a-zA-Z0-9_:\-]*$/

    private var commands: [String: CommandEntry] = [:]

    func register(_ entry: CommandEntry) throws {
        guard entry.name.wholeMatch(of: Self.validNameRegex) != nil else {
            throw CommandError.invalidName(entry.name)
        }
        commands[entry.name] = entry
    }

    func unregister(_ name: String) {
        commands.removeValue(forKey: name)
    }

    func clear() {
        commands.removeAll()
    }

    func entry(for itemId: String) -> CommandEntry? {
        guard let name = Self.extractName(from: itemId) else { return nil }
        return commands[name]
    }

    func search(query: String) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            return commands.values
                .sorted { $0.name < $1.name }
                .map { makeResult(entry: $0, args: "", score: 50) }
        }

        // Args mode: first word exact match + space separator
        if let spaceIndex = trimmed.firstIndex(of: " ") {
            let namePart = String(trimmed[trimmed.startIndex..<spaceIndex])
            if let cmd = commands[namePart] {
                let args = String(trimmed[trimmed.index(after: spaceIndex)...])
                return [makeResult(entry: cmd, args: args, score: 100)]
            }
        }

        // Fuzzy search
        return fuzzySearch(Array(commands.values), query: trimmed)
    }

    func promotedSearch(query: String) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let promoted = commands.values.filter(\.promoted)
        guard !promoted.isEmpty else { return [] }

        return fuzzySearch(promoted, query: trimmed)
    }

    private nonisolated func fuzzySearch(_ entries: [CommandEntry], query: String) -> [SearchResult] {
        scoredItems(from: entries, query: query, names: {
            [$0.title, $0.name]
        }).map { item, score in
            makeResult(entry: item, args: "", score: score)
        }
    }

    private nonisolated func makeResult(entry: CommandEntry, args: String, score: Double) -> SearchResult {
        var subtitle = entry.subtitle
        if !args.isEmpty {
            subtitle = subtitle.isEmpty ? "args: \(args)" : "\(subtitle)  ·  args: \(args)"
        }

        return SearchResult(
            itemId: "\(Self.itemIdPrefix)\(entry.name)",
            icon: entry.icon,
            name: entry.title,
            subtitle: subtitle,
            resultType: .command,
            url: nil,
            score: score,
            actionContext: args
        )
    }
}
