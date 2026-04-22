import Foundation

@MainActor
final class SearchRouter {
    struct ProviderEntry: Sendable {
        let id: String
        let provider: SearchProvider
        var prefix: String?
    }

    private var entries: [ProviderEntry] = []
    private(set) var maxResults: Int
    private var disabledIds: Set<String> = []

    init(defaultProvider: SearchProvider, maxResults: Int = 50) {
        entries.append(ProviderEntry(id: "default", provider: defaultProvider, prefix: nil))
        self.maxResults = maxResults
    }

    func setMaxResults(_ value: Int) {
        maxResults = value
    }

    func setEnabled(_ enabled: Bool, forId id: String) {
        if enabled {
            disabledIds.remove(id)
        } else {
            disabledIds.insert(id)
        }
    }

    func isEnabled(id: String) -> Bool {
        !disabledIds.contains(id)
    }

    func updatePrefix(_ newPrefix: String, forId id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let normalized = Self.normalizePrefix(newPrefix) else { return }
        entries[index].prefix = normalized
    }

    func registerDefault(id: String, provider: SearchProvider) {
        entries.append(ProviderEntry(id: id, provider: provider, prefix: nil))
    }

    func register(prefix: String, id: String? = nil, provider: SearchProvider) {
        guard let normalized = Self.normalizePrefix(prefix) else { return }
        entries.append(ProviderEntry(id: id ?? prefix, provider: provider, prefix: normalized))
    }

    func unregister(id: String) {
        entries.removeAll { $0.id == id }
        disabledIds.remove(id)
    }

    private static func normalizePrefix(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed + " "
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

    func hasPreviewProvider(for rawQuery: String) -> Bool {
        matchedEntries(for: rawQuery).contains { $0.provider.supportsPreview }
    }

    /// Check whether a specific provider would handle the given raw query.
    func hasActiveProvider(id: String, for rawQuery: String) -> Bool {
        matchedEntries(for: rawQuery).contains { $0.id == id }
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
        return results?.map { result in
            var r = result
            r.sourceProviderId = entry.id
            return r
        } ?? []
    }

    func tabComplete(rawQuery: String, selectedItem: SearchResult) async -> String? {
        guard let providerId = selectedItem.sourceProviderId,
              let entry = entries.first(where: { $0.id == providerId }) else {
            return nil
        }
        let stripped = strippedQuery(rawQuery: rawQuery, entries: [entry])
        return await entry.provider.tabComplete(
            rawQuery: rawQuery,
            strippedQuery: stripped,
            selectedItem: selectedItem
        )
    }

    private func matchedEntries(for rawQuery: String) -> [ProviderEntry] {
        let active = entries.filter { isEnabled(id: $0.id) }
        let prefixMatched = active.filter { entry in
            guard let prefix = entry.prefix else { return false }
            return rawQuery.hasPrefix(prefix)
        }
        if prefixMatched.isEmpty {
            return active.filter { $0.prefix == nil }
        }
        let longestLen = prefixMatched.compactMap { $0.prefix?.count }.max() ?? 0
        return prefixMatched.filter { $0.prefix?.count == longestLen }
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
