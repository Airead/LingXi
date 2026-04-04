import AppKit

final class FileSearchProvider: SearchProvider, Sendable {
    static let maxResults = 20
    private static let minQueryLength = 1
    private static let homeDirectory = NSHomeDirectory()

    private static let modifierActions = ModifierAction.defaultFileActions

    private let searcher: MDQuerySearching
    private let scope: [String]
    private let contentType: ContentTypeFilter

    init(searcher: MDQuerySearching = MDQuerySearch(), scope: [String] = [NSHomeDirectory()], contentType: ContentTypeFilter = .any) {
        self.searcher = searcher
        self.scope = scope
        self.contentType = contentType
    }

    var debounceMilliseconds: Int { 60 }
    var timeoutMilliseconds: Int { 5000 }

    func search(query: String) async -> [SearchResult] {
        guard query.count >= Self.minQueryLength else { return [] }

        let includeHidden = query.hasPrefix(".")

        let fileResults = await searcher.search(
            name: query,
            scope: scope,
            maxResults: Self.maxResults,
            includeHidden: includeHidden,
            contentType: contentType
        )

        var iconCache: [String: NSImage] = [:]
        var results: [SearchResult] = []

        for (index, file) in fileResults.enumerated() {
            let url = URL(fileURLWithPath: file.path)
            let ext = url.pathExtension
            let icon: NSImage
            if !ext.isEmpty, let cached = iconCache[ext] {
                icon = cached
            } else {
                icon = NSWorkspace.shared.icon(forFile: file.path)
                if !ext.isEmpty {
                    iconCache[ext] = icon
                }
            }
            let subtitle = Self.shortenPath(url.deletingLastPathComponent().path)
            let score = Double(Self.maxResults - index)

            results.append(SearchResult(
                itemId: file.path,
                icon: icon,
                name: file.name,
                subtitle: subtitle,
                resultType: .file,
                url: url,
                score: score,
                modifierActions: Self.modifierActions
            ))
        }

        return results
    }

    static func shortenPath(_ path: String) -> String {
        if path.hasPrefix(homeDirectory) {
            return "~" + path.dropFirst(homeDirectory.count)
        }
        return path
    }
}
