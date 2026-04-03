import AppKit

struct MockSearchProvider: SearchProvider {
    private static let mockData: [SearchResult] = [
        SearchResult(icon: NSImage(systemSymbolName: "safari", accessibilityDescription: nil),
                     name: "Safari", subtitle: "Web Browser", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "note.text", accessibilityDescription: nil),
                     name: "Notes", subtitle: "Apple Notes", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "plus.forwardslash.minus", accessibilityDescription: nil),
                     name: "Calculator", subtitle: "Utility", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil),
                     name: "Calendar", subtitle: "Apple Calendar", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "envelope", accessibilityDescription: nil),
                     name: "Mail", subtitle: "Apple Mail", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "map", accessibilityDescription: nil),
                     name: "Maps", subtitle: "Apple Maps", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "gear", accessibilityDescription: nil),
                     name: "System Settings", subtitle: "Preferences", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil),
                     name: "Terminal", subtitle: "Utility", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil),
                     name: "Music", subtitle: "Apple Music", resultType: .application),
        SearchResult(icon: NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
                     name: "Photos", subtitle: "Apple Photos", resultType: .application),
    ]

    func search(query: String) async -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return Self.mockData
            .compactMap { result in
                var scored = result
                let name = result.name.lowercased()
                if name.hasPrefix(q) {
                    scored.score = 100
                    return scored
                } else if name.contains(q) {
                    scored.score = 50
                    return scored
                }
                return nil
            }
            .sorted { $0.score > $1.score }
    }
}
