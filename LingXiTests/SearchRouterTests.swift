import Testing
@testable import LingXi

// MARK: - Test helpers

private struct StubProvider: SearchProvider {
    let label: String
    func search(query: String) async -> [SearchResult] {
        [SearchResult(itemId: label, icon: nil, name: label, subtitle: query, resultType: .application, url: nil, score: 1)]
    }
}

private struct DelayedProvider: SearchProvider {
    let label: String
    let delayMilliseconds: UInt64
    let score: Double

    init(label: String, delayMilliseconds: UInt64, score: Double = 1.0) {
        self.label = label
        self.delayMilliseconds = delayMilliseconds
        self.score = score
    }

    func search(query: String) async -> [SearchResult] {
        try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
        guard !Task.isCancelled else { return [] }
        return [SearchResult(itemId: label, icon: nil, name: label, subtitle: query, resultType: .application, url: nil, score: score)]
    }
}

private struct MultiResultProvider: SearchProvider {
    let items: [SearchResult]
    func search(query: String) async -> [SearchResult] { items }
}

private struct FailingProvider: SearchProvider {
    func search(query: String) async -> [SearchResult] { [] }
}

private struct TimeoutConfiguredProvider: SearchProvider {
    let label: String
    var timeoutMilliseconds: Int { 50 }

    func search(query: String) async -> [SearchResult] {
        try? await Task.sleep(nanoseconds: 200 * 1_000_000)
        guard !Task.isCancelled else { return [] }
        return [SearchResult(itemId: label, icon: nil, name: label, subtitle: query, resultType: .application, url: nil, score: 1)]
    }
}

// MARK: - Basic routing tests

@MainActor
struct SearchRouterTests {

    @Test func routeWithNoPrefix() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        let results = await router.search(rawQuery: "hello")
        #expect(results.first?.name == "default")
        #expect(results.first?.subtitle == "hello")
    }

    @Test func routeWithRegisteredPrefix() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "f ", provider: StubProvider(label: "file"))
        let results = await router.search(rawQuery: "f readme")
        #expect(results.first?.name == "file")
        #expect(results.first?.subtitle == "readme")
    }

    @Test func routeWithUnmatchedPrefix() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "f ", provider: StubProvider(label: "file"))
        let results = await router.search(rawQuery: "> ls")
        #expect(results.first?.name == "default")
        #expect(results.first?.subtitle == "> ls")
    }

    @Test func longestPrefixMatchWins() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "f ", provider: StubProvider(label: "file"))
        router.register(prefix: "fd ", provider: StubProvider(label: "folder"))
        let results = await router.search(rawQuery: "fd docs")
        #expect(results.count == 1)
        #expect(results.first?.name == "folder")
        #expect(results.first?.subtitle == "docs")
    }

    @Test func shorterPrefixStillWorksWhenLongerDoesNotMatch() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "f ", provider: StubProvider(label: "file"))
        router.register(prefix: "fd ", provider: StubProvider(label: "folder"))
        let results = await router.search(rawQuery: "f readme")
        #expect(results.count == 1)
        #expect(results.first?.name == "file")
    }

    @Test func routeStripsOnlyPrefix() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "> ", provider: StubProvider(label: "cmd"))
        let results = await router.search(rawQuery: "> open file")
        #expect(results.first?.name == "cmd")
        #expect(results.first?.subtitle == "open file")
    }

    @Test func updatePrefixChangesRouting() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "f ", id: "file", provider: StubProvider(label: "file"))

        router.updatePrefix("fi", forId: "file")

        let results = await router.search(rawQuery: "fi readme")
        #expect(results.first?.name == "file")
        #expect(results.first?.subtitle == "readme")

        // Old prefix should no longer match
        let oldResults = await router.search(rawQuery: "f readme")
        #expect(oldResults.first?.name == "default")
    }

    @Test func updatePrefixForNonExistentIdIsNoOp() {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.updatePrefix("x", forId: "nonexistent")
        // No crash, no change
    }
}

// MARK: - Multi-provider parallel tests

@MainActor
struct SearchRouterIncrementalTests {

    @Test func multipleDefaultProvidersReturnMergedResults() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "provider1"))
        router.registerDefault(id: "provider2", provider: StubProvider(label: "provider2"))
        let results = await router.search(rawQuery: "test")
        #expect(results.count == 2)
        let names = Set(results.map(\.name))
        #expect(names.contains("provider1"))
        #expect(names.contains("provider2"))
    }

    @Test func multiplePrefixProvidersReturnMergedResults() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "f ", id: "file1", provider: StubProvider(label: "file1"))
        router.register(prefix: "f ", id: "file2", provider: StubProvider(label: "file2"))
        let results = await router.search(rawQuery: "f readme")
        #expect(results.count == 2)
        let names = Set(results.map(\.name))
        #expect(names.contains("file1"))
        #expect(names.contains("file2"))
    }

    @Test func incrementalCallbackCalledPerProvider() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "p1"))
        router.registerDefault(id: "p2", provider: StubProvider(label: "p2"))

        let collector = CallbackCollector()
        await router.searchIncremental(rawQuery: "test") { providerId, results in
            await collector.record(providerId: providerId, count: results.count)
        }

        let records = await collector.records
        #expect(records.count == 2)
        let ids = Set(records.map(\.providerId))
        #expect(ids.contains("default"))
        #expect(ids.contains("p2"))
    }

    @Test func fastProviderResultsArriveBeforeSlowProvider() async {
        let fast = DelayedProvider(label: "fast", delayMilliseconds: 0, score: 50)
        let slow = DelayedProvider(label: "slow", delayMilliseconds: 100, score: 100)
        let router = SearchRouter(defaultProvider: fast)
        router.registerDefault(id: "slow", provider: slow)

        let collector = CallbackCollector()
        await router.searchIncremental(rawQuery: "test") { providerId, results in
            await collector.record(providerId: providerId, count: results.count)
        }

        let records = await collector.records
        #expect(records.count == 2)
        #expect(records[0].providerId == "default")
        #expect(records[1].providerId == "slow")
    }

    @Test func providerTimeoutDropsSlowResults() async {
        let normal = StubProvider(label: "normal")
        let timedOut = TimeoutConfiguredProvider(label: "slow")
        let router = SearchRouter(defaultProvider: normal)
        router.registerDefault(id: "slow", provider: timedOut)

        let results = await router.search(rawQuery: "test")
        // Only normal provider returns results; slow one times out
        #expect(results.count == 1)
        #expect(results.first?.name == "normal")
    }

    @Test func failingProviderDoesNotAffectOthers() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "good"))
        router.registerDefault(id: "bad", provider: FailingProvider())
        let results = await router.search(rawQuery: "test")
        #expect(results.count == 1)
        #expect(results.first?.name == "good")
    }

    @Test func maxResultsTruncation() async {
        var items: [SearchResult] = []
        for i in 0..<30 {
            items.append(SearchResult(itemId: "item\(i)", icon: nil, name: "Item\(i)", subtitle: "",
                                      resultType: .application, url: nil, score: Double(30 - i)))
        }
        let provider1 = MultiResultProvider(items: items)
        var items2: [SearchResult] = []
        for i in 30..<60 {
            items2.append(SearchResult(itemId: "item\(i)", icon: nil, name: "Item\(i)", subtitle: "",
                                       resultType: .application, url: nil, score: Double(60 - i)))
        }
        let provider2 = MultiResultProvider(items: items2)

        let router = SearchRouter(defaultProvider: provider1, maxResults: 50)
        router.registerDefault(id: "p2", provider: provider2)
        let results = await router.search(rawQuery: "test")
        #expect(results.count == 50)
    }

    @Test func searchResultsSortedByScore() async {
        let p1 = StubProvider(label: "low")
        let p2 = DelayedProvider(label: "high", delayMilliseconds: 0, score: 100)
        let router = SearchRouter(defaultProvider: p1)
        router.registerDefault(id: "p2", provider: p2)
        let results = await router.search(rawQuery: "test")
        #expect(results.count == 2)
        #expect(results[0].itemId == "high")
        #expect(results[1].itemId == "low")
    }
}

// MARK: - Enable/disable tests

@MainActor
struct SearchRouterEnableDisableTests {

    @Test func disableDefaultProvider() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.setEnabled(false, forId: "default")
        let results = await router.search(rawQuery: "hello")
        #expect(results.isEmpty)
    }

    @Test func disablePrefixProvider() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "f ", id: "file", provider: StubProvider(label: "file"))
        router.setEnabled(false, forId: "file")

        let results = await router.search(rawQuery: "f readme")
        // Falls back to default since prefix provider is disabled
        #expect(results.first?.name == "default")
    }

    @Test func reEnableProvider() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "f ", id: "file", provider: StubProvider(label: "file"))
        router.setEnabled(false, forId: "file")
        router.setEnabled(true, forId: "file")

        let results = await router.search(rawQuery: "f readme")
        #expect(results.first?.name == "file")
    }

    @Test func isEnabledReflectsState() {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        #expect(router.isEnabled(id: "default") == true)
        router.setEnabled(false, forId: "default")
        #expect(router.isEnabled(id: "default") == false)
        router.setEnabled(true, forId: "default")
        #expect(router.isEnabled(id: "default") == true)
    }

    @Test func setMaxResults() async {
        var items: [SearchResult] = []
        for i in 0..<30 {
            items.append(SearchResult(itemId: "item\(i)", icon: nil, name: "Item\(i)", subtitle: "",
                                      resultType: .application, url: nil, score: Double(30 - i)))
        }
        let router = SearchRouter(defaultProvider: MultiResultProvider(items: items), maxResults: 50)
        router.setMaxResults(10)
        let results = await router.search(rawQuery: "test")
        #expect(results.count == 10)
    }
}

// MARK: - Test callback collector

private actor CallbackCollector {
    struct Record {
        let providerId: String
        let count: Int
    }
    var records: [Record] = []

    func record(providerId: String, count: Int) {
        records.append(Record(providerId: providerId, count: count))
    }
}
