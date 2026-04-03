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
        scoredResults(from: items, query: query, names: { [name($0)] }, transform: transform)
    }

    func scoredResults<T>(
        from items: [T],
        query: String,
        names: (T) -> [String],
        transform: (T, Double) -> SearchResult
    ) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return items
            .compactMap { item -> SearchResult? in
                var bestScore: Double = 0
                for n in names(item) {
                    let lower = n.lowercased()
                    if lower.hasPrefix(q) {
                        bestScore = max(bestScore, SearchScore.prefixMatch)
                    } else if lower.contains(q) {
                        bestScore = max(bestScore, SearchScore.containsMatch)
                    }
                }
                guard bestScore > 0 else { return nil }
                return transform(item, bestScore)
            }
            .sorted { $0.score > $1.score }
    }
}
