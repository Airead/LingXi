protocol SearchProvider: Sendable {
    func search(query: String) async -> [SearchResult]
    var debounceMilliseconds: Int { get }
    var timeoutMilliseconds: Int { get }
    var supportsPreview: Bool { get }
    func tabComplete(rawQuery: String, strippedQuery: String, selectedItem: SearchResult) async -> String?
}

extension SearchProvider {
    var debounceMilliseconds: Int { 0 }
    var timeoutMilliseconds: Int { 5000 }
    var supportsPreview: Bool { false }

    func tabComplete(rawQuery: String, strippedQuery: String, selectedItem: SearchResult) async -> String? {
        nil
    }
}

extension SearchProvider {
    nonisolated func scoredItems<T>(
        from items: [T],
        query: String,
        name: (T) -> String
    ) -> [(item: T, score: Double)] {
        scoredItems(from: items, query: query, names: { [name($0)] })
    }

    nonisolated func scoredItems<T>(
        from items: [T],
        query: String,
        names: (T) -> [String]
    ) -> [(item: T, score: Double)] {
        guard !query.isEmpty else { return [] }
        return items
            .compactMap { item -> (item: T, score: Double)? in
                guard let score = FuzzyMatch.matchFields(query: query, fields: names(item)) else {
                    return nil
                }
                return (item, score)
            }
            .sorted { $0.score > $1.score }
    }
}
