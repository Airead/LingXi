import Combine
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { filterResults() }
    }
    @Published private(set) var results: [SearchResult] = []

    private let mockData: [SearchResult] = [
        SearchResult(icon: "safari", name: "Safari", subtitle: "Web Browser"),
        SearchResult(icon: "note.text", name: "Notes", subtitle: "Apple Notes"),
        SearchResult(icon: "plus.forwardslash.minus", name: "Calculator", subtitle: "Utility"),
        SearchResult(icon: "calendar", name: "Calendar", subtitle: "Apple Calendar"),
        SearchResult(icon: "envelope", name: "Mail", subtitle: "Apple Mail"),
        SearchResult(icon: "map", name: "Maps", subtitle: "Apple Maps"),
        SearchResult(icon: "gear", name: "System Settings", subtitle: "Preferences"),
        SearchResult(icon: "terminal", name: "Terminal", subtitle: "Utility"),
        SearchResult(icon: "music.note", name: "Music", subtitle: "Apple Music"),
        SearchResult(icon: "photo", name: "Photos", subtitle: "Apple Photos"),
    ]

    func clear() {
        query = ""
    }

    private func filterResults() {
        guard !query.isEmpty else {
            results = []
            return
        }
        results = mockData.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
