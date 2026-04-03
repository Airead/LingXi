import AppKit

enum SearchResultType {
    case application
    case file
    case command
    case bookmark
}

struct SearchResult: Identifiable {
    let id = UUID()
    let itemId: String
    let icon: NSImage?
    let name: String
    let subtitle: String
    let resultType: SearchResultType
    let url: URL?
    var score: Double
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
