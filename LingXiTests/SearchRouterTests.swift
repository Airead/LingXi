import Testing
@testable import LingXi

struct SearchRouterTests {

    private struct StubProvider: SearchProvider {
        let label: String
        func search(query: String) async -> [SearchResult] {
            [SearchResult(itemId: label, icon: nil, name: label, subtitle: query, resultType: .application, url: nil, score: 1)]
        }
    }

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

    @Test func routeStripsOnlyPrefix() async {
        let router = SearchRouter(defaultProvider: StubProvider(label: "default"))
        router.register(prefix: "> ", provider: StubProvider(label: "cmd"))
        let results = await router.search(rawQuery: "> open file")
        #expect(results.first?.name == "cmd")
        #expect(results.first?.subtitle == "open file")
    }
}
