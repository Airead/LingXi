enum SearchScore {
    static let prefixMatch: Double = 100
    static let containsMatch: Double = 50
}

protocol SearchProvider {
    func search(query: String) async -> [SearchResult]
}

extension SearchProvider {
    func scoredResults<T>(
        from items: [T],
        query: String,
        name: (T) -> String,
        transform: (T, Double) -> SearchResult
    ) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return items
            .compactMap { item -> SearchResult? in
                let n = name(item).lowercased()
                let score: Double
                if n.hasPrefix(q) {
                    score = SearchScore.prefixMatch
                } else if n.contains(q) {
                    score = SearchScore.containsMatch
                } else {
                    return nil
                }
                return transform(item, score)
            }
            .sorted { $0.score > $1.score }
    }
}
