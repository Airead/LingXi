import Foundation

final class SearchRouter {
    struct ProviderEntry: Sendable {
        let id: String
        let provider: SearchProvider
        let prefix: String?
    }

    private var entries: [ProviderEntry] = []
    let maxResults: Int

    init(defaultProvider: SearchProvider, maxResults: Int = 50) {
        entries.append(ProviderEntry(id: "default", provider: defaultProvider, prefix: nil))
        self.maxResults = maxResults
    }

    func registerDefault(id: String, provider: SearchProvider) {
        entries.append(ProviderEntry(id: id, provider: provider, prefix: nil))
    }

    func register(prefix: String, id: String? = nil, provider: SearchProvider) {
        entries.append(ProviderEntry(id: id ?? prefix, provider: provider, prefix: prefix))
    }

    func search(rawQuery: String) async -> [SearchResult] {
        let matched = matchedEntries(for: rawQuery)
        let query = strippedQuery(rawQuery: rawQuery, entries: matched)

        let allResults = await withTaskGroup(of: [SearchResult].self) { group in
            for entry in matched {
                group.addTask { await Self.executeProvider(entry, query: query) }
            }
            var collected: [SearchResult] = []
            for await batch in group {
                collected.append(contentsOf: batch)
            }
            return collected
        }
        return allResults.sortedAndTruncated(maxResults: maxResults)
    }

    func searchIncremental(
        rawQuery: String,
        onResults: @escaping @Sendable (_ providerId: String, _ results: [SearchResult]) async -> Void
    ) async {
        let matched = matchedEntries(for: rawQuery)
        let query = strippedQuery(rawQuery: rawQuery, entries: matched)

        await withTaskGroup(of: Void.self) { group in
            for entry in matched {
                group.addTask {
                    let results = await Self.executeProvider(entry, query: query)
                    guard !Task.isCancelled, !results.isEmpty else { return }
                    await onResults(entry.id, results)
                }
            }
        }
    }

    // MARK: - Private helpers

    private static func executeProvider(_ entry: ProviderEntry, query: String) async -> [SearchResult] {
        let debounceNs = UInt64(entry.provider.debounceMilliseconds) * 1_000_000
        if debounceNs > 0 {
            try? await Task.sleep(nanoseconds: debounceNs)
            guard !Task.isCancelled else { return [] }
        }

        let timeoutNs = UInt64(entry.provider.timeoutMilliseconds) * 1_000_000
        let results: [SearchResult]? = await withTaskTimeout(nanoseconds: timeoutNs) {
            await entry.provider.search(query: query)
        }
        return results ?? []
    }

    private func matchedEntries(for rawQuery: String) -> [ProviderEntry] {
        let prefixMatched = entries.filter { entry in
            guard let prefix = entry.prefix else { return false }
            return rawQuery.hasPrefix(prefix)
        }
        if !prefixMatched.isEmpty {
            return prefixMatched
        }
        return entries.filter { $0.prefix == nil }
    }

    private func strippedQuery(rawQuery: String, entries: [ProviderEntry]) -> String {
        if let prefix = entries.first?.prefix {
            return String(rawQuery.dropFirst(prefix.count))
        }
        return rawQuery
    }
}

// MARK: - Timeout helper

private func withTaskTimeout<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
