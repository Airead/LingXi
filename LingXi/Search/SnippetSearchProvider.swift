import AppKit

actor SnippetSearchProvider: SearchProvider {
    nonisolated let supportsPreview = true
    nonisolated static let itemIdPrefix = "snippet:"

    nonisolated static func extractId(from itemId: String) -> String? {
        guard itemId.hasPrefix(itemIdPrefix) else { return nil }
        return String(itemId.dropFirst(itemIdPrefix.count))
    }

    nonisolated static let snippetIcon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Snippet")

    private let store: SnippetStore

    init(store: SnippetStore) {
        self.store = store
    }

    func search(query: String) async -> [SearchResult] {
        let snippets = await store.allSnippets()

        if query.isEmpty {
            return snippets.map { makeResult(snippet: $0, score: 50) }
        }

        return scoredItems(from: snippets, query: query, names: { snippet in
            [snippet.name, snippet.keyword, snippet.content, snippet.category]
        }).map { item, score in
            makeResult(snippet: item, score: score)
        }
    }

    private nonisolated func makeResult(snippet: Snippet, score: Double) -> SearchResult {
        var title = snippet.name
        if !snippet.keyword.isEmpty {
            title += "  [\(snippet.keyword)]"
        }
        if !snippet.category.isEmpty {
            title += "  ·  \(snippet.category)"
        }
        if snippet.isRandom, snippet.variants.count > 1 {
            title += "  (\(snippet.variants.count) variants)"
        }

        let displayContent = snippet.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let subtitle = displayContent.count > 60
            ? String(displayContent.prefix(57)) + "..."
            : displayContent

        let itemId: String
        if snippet.category.isEmpty {
            itemId = "\(Self.itemIdPrefix)\(snippet.name)"
        } else {
            itemId = "\(Self.itemIdPrefix)\(snippet.category)/\(snippet.name)"
        }

        return SearchResult(
            itemId: itemId,
            icon: Self.snippetIcon,
            name: title,
            subtitle: subtitle,
            resultType: .snippet,
            url: URL(fileURLWithPath: snippet.filePath),
            score: score,
            previewData: .text(snippet.previewContent),
            modifierActions: [
                .command: ModifierAction(subtitle: "Copy to Clipboard") { result in
                    let text = snippet.resolvedContent()
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    return true
                },
                .option: ModifierAction(subtitle: "Edit in TextEdit") { result in
                    guard let url = result.url else { return false }
                    NSWorkspace.shared.open(
                        [url],
                        withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                    return true
                },
            ]
        )
    }
}
