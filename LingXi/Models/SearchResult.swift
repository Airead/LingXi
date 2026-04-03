import AppKit

enum SearchResultType {
    case application
    case file
    case command
    case bookmark
}

struct SearchResult: Identifiable {
    let id = UUID()
    let icon: NSImage?
    let name: String
    let subtitle: String
    let resultType: SearchResultType
    let url: URL?
    let score: Double
}
