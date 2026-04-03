import AppKit

struct MockSearchProvider: SearchProvider {
    private static let mockData: [MockEntry] = [
        MockEntry(icon: NSImage(systemSymbolName: "safari", accessibilityDescription: nil),
                  name: "Safari", subtitle: "Web Browser"),
        MockEntry(icon: NSImage(systemSymbolName: "note.text", accessibilityDescription: nil),
                  name: "Notes", subtitle: "Apple Notes"),
        MockEntry(icon: NSImage(systemSymbolName: "plus.forwardslash.minus", accessibilityDescription: nil),
                  name: "Calculator", subtitle: "Utility"),
        MockEntry(icon: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil),
                  name: "Calendar", subtitle: "Apple Calendar"),
        MockEntry(icon: NSImage(systemSymbolName: "envelope", accessibilityDescription: nil),
                  name: "Mail", subtitle: "Apple Mail"),
        MockEntry(icon: NSImage(systemSymbolName: "map", accessibilityDescription: nil),
                  name: "Maps", subtitle: "Apple Maps"),
        MockEntry(icon: NSImage(systemSymbolName: "gear", accessibilityDescription: nil),
                  name: "System Settings", subtitle: "Preferences"),
        MockEntry(icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil),
                  name: "Terminal", subtitle: "Utility"),
        MockEntry(icon: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil),
                  name: "Music", subtitle: "Apple Music"),
        MockEntry(icon: NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
                  name: "Photos", subtitle: "Apple Photos"),
    ]

    private struct MockEntry {
        let icon: NSImage?
        let name: String
        let subtitle: String
    }

    func search(query: String) async -> [SearchResult] {
        scoredResults(from: Self.mockData, query: query, name: \.name) { entry, score in
            SearchResult(icon: entry.icon, name: entry.name, subtitle: entry.subtitle,
                         resultType: .application, url: nil, score: score)
        }
    }
}
