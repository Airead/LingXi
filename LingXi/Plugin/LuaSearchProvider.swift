import Foundation

/// A SearchProvider backed by a Lua plugin script.
/// Each instance owns its own LuaState; the actor serializes access.
actor LuaSearchProvider: SearchProvider {
    nonisolated static let idPrefix = "lua:"

    nonisolated let name: String
    nonisolated let pluginDir: URL

    nonisolated let debounceMilliseconds: Int
    nonisolated let timeoutMilliseconds: Int
    nonisolated var supportsPreview: Bool { false }

    private let state: LuaState

    init(name: String, pluginDir: URL, state: LuaState, debounce: Int = 100, timeout: Int = 5000) {
        self.name = name
        self.pluginDir = pluginDir
        self.debounceMilliseconds = debounce
        self.timeoutMilliseconds = timeout
        self.state = state
    }

    func search(query: String) async -> [SearchResult] {
        parseResults(query: query)
    }

    // MARK: - Private

    private func parseResults(query: String) -> [SearchResult] {
        state.getGlobal("search")
        guard state.isFunction(at: -1) else {
            state.pop()
            return []
        }

        state.push(query)
        do {
            try state.pcall(nargs: 1, nresults: 1)
        } catch {
            DebugLog.log("[LuaPlugin:\(name)] search error: \(error)")
            return [errorResult("\(error)")]
        }

        defer { state.pop() }

        guard state.isTable(at: -1) else { return [] }

        var results: [SearchResult] = []
        state.iterateArray(at: -1) {
            if let result = parseOneResult(at: -1) {
                results.append(result)
            }
        }
        return results
    }

    private func errorResult(_ message: String) -> SearchResult {
        SearchResult(
            itemId: "\(Self.idPrefix)\(name):error",
            icon: nil,
            name: "Plugin error: \(name)",
            subtitle: message,
            resultType: .command,
            url: nil,
            score: 100
        )
    }

    private func parseOneResult(at index: Int32) -> SearchResult? {
        guard state.isTable(at: index) else { return nil }

        let title = state.stringField("title", at: index) ?? ""
        guard !title.isEmpty else { return nil }

        let subtitle = state.stringField("subtitle", at: index) ?? ""
        let urlString = state.stringField("url", at: index)
        let score = state.numberField("score", at: index) ?? 50.0

        let url: URL? = urlString.flatMap { URL(string: $0) }
        let itemId = "\(Self.idPrefix)\(name):\(title)"

        return SearchResult(
            itemId: itemId,
            icon: nil,
            name: title,
            subtitle: subtitle,
            resultType: .command,
            url: url,
            score: score
        )
    }
}
