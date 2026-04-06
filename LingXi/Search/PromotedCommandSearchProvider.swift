actor PromotedCommandSearchProvider: SearchProvider {
    private let commandProvider: CommandSearchProvider

    init(commandProvider: CommandSearchProvider) {
        self.commandProvider = commandProvider
    }

    func search(query: String) async -> [SearchResult] {
        await commandProvider.promotedSearch(query: query)
    }
}
