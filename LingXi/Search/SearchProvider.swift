protocol SearchProvider {
    func search(query: String) async -> [SearchResult]
}
