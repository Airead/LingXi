import Combine
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { filterResults() }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0

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

    func moveUp() {
        guard !results.isEmpty, selectedIndex > 0 else { return }
        selectedIndex -= 1
    }

    func moveDown() {
        guard !results.isEmpty, selectedIndex < results.count - 1 else { return }
        selectedIndex += 1
    }

    func confirm() {
        guard results.indices.contains(selectedIndex) else { return }
        let selected = results[selectedIndex]
        print("[LingXi] Selected: \(selected.name) — \(selected.subtitle)")
    }

    private func filterResults() {
        guard !query.isEmpty else {
            results = []
            selectedIndex = 0
            return
        }
        results = mockData.filter { $0.name.localizedCaseInsensitiveContains(query) }
        selectedIndex = 0
    }
}
