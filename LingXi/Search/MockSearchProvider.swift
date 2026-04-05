import AppKit

struct MockSearchProvider: SearchProvider {
    private static let mockData: [MockEntry] = [
        MockEntry(itemId: "com.apple.Safari", icon: NSImage(systemSymbolName: "safari", accessibilityDescription: nil),
                  name: "Safari", subtitle: "Web Browser"),
        MockEntry(itemId: "com.apple.Notes", icon: NSImage(systemSymbolName: "note.text", accessibilityDescription: nil),
                  name: "Notes", subtitle: "Apple Notes"),
        MockEntry(itemId: "com.apple.calculator", icon: NSImage(systemSymbolName: "plus.forwardslash.minus", accessibilityDescription: nil),
                  name: "Calculator", subtitle: "Utility"),
        MockEntry(itemId: "com.apple.iCal", icon: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil),
                  name: "Calendar", subtitle: "Apple Calendar"),
        MockEntry(itemId: "com.apple.mail", icon: NSImage(systemSymbolName: "envelope", accessibilityDescription: nil),
                  name: "Mail", subtitle: "Apple Mail"),
        MockEntry(itemId: "com.apple.Maps", icon: NSImage(systemSymbolName: "map", accessibilityDescription: nil),
                  name: "Maps", subtitle: "Apple Maps"),
        MockEntry(itemId: "com.apple.systempreferences", icon: NSImage(systemSymbolName: "gear", accessibilityDescription: nil),
                  name: "System Settings", subtitle: "Preferences"),
        MockEntry(itemId: "com.apple.Terminal", icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil),
                  name: "Terminal", subtitle: "Utility"),
        MockEntry(itemId: "com.apple.Music", icon: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil),
                  name: "Music", subtitle: "Apple Music"),
        MockEntry(itemId: "com.apple.Photos", icon: NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
                  name: "Photos", subtitle: "Apple Photos"),
    ]

    private struct MockEntry {
        let itemId: String
        let icon: NSImage?
        let name: String
        let subtitle: String
    }

    func search(query: String) async -> [SearchResult] {
        scoredItems(from: Self.mockData, query: query, name: \.name).map { entry, score in
            SearchResult(itemId: entry.itemId, icon: entry.icon, name: entry.name, subtitle: entry.subtitle,
                         resultType: .application, url: nil, score: score)
        }
    }
}
