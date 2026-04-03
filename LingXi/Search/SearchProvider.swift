protocol SearchProvider: Sendable {
    func search(query: String) async -> [SearchResult]
    var debounceMilliseconds: Int { get }
    var timeoutMilliseconds: Int { get }
}

extension SearchProvider {
    var debounceMilliseconds: Int { 0 }
    var timeoutMilliseconds: Int { 5000 }
}

extension SearchProvider {
    func scoredResults<T>(
        from items: [T],
        query: String,
        name: (T) -> String,
        transform: (T, Double) -> SearchResult
    ) -> [SearchResult] {
        scoredResults(from: items, query: query, names: { [name($0)] }, transform: transform)
    }

    func scoredResults<T>(
        from items: [T],
        query: String,
        names: (T) -> [String],
        transform: (T, Double) -> SearchResult
    ) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        return items
            .compactMap { item -> SearchResult? in
                guard let score = FuzzyMatch.matchFields(query: query, fields: names(item)) else {
                    return nil
                }
                return transform(item, score)
            }
            .sorted { $0.score > $1.score }
    }
}
