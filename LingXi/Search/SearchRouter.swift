final class SearchRouter {
    private var prefixProviders: [(prefix: String, provider: SearchProvider)] = []
    private var defaultProvider: SearchProvider

    init(defaultProvider: SearchProvider) {
        self.defaultProvider = defaultProvider
    }

    func register(prefix: String, provider: SearchProvider) {
        prefixProviders.append((prefix, provider))
    }

    func search(rawQuery: String) async -> [SearchResult] {
        for entry in prefixProviders {
            if rawQuery.hasPrefix(entry.prefix) {
                let query = String(rawQuery.dropFirst(entry.prefix.count))
                return await entry.provider.search(query: query)
            }
        }
        return await defaultProvider.search(query: rawQuery)
    }
}
