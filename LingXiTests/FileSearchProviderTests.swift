import Foundation
import Testing
@testable import LingXi

private struct MockMDQuery: MDQuerySearching {
    let results: [MDQuerySearch.FileResult]

    func search(name: String, scope: [String], maxResults: Int, includeHidden: Bool, contentType: ContentTypeFilter) async -> [MDQuerySearch.FileResult] {
        Array(results.prefix(maxResults))
    }
}

private final class CapturingMDQuery: MDQuerySearching, @unchecked Sendable {
    private(set) var lastIncludeHidden: Bool?
    private(set) var lastContentType: ContentTypeFilter?

    let results: [MDQuerySearch.FileResult]

    init(results: [MDQuerySearch.FileResult] = []) {
        self.results = results
    }

    func search(name: String, scope: [String], maxResults: Int, includeHidden: Bool, contentType: ContentTypeFilter) async -> [MDQuerySearch.FileResult] {
        lastIncludeHidden = includeHidden
        lastContentType = contentType
        return Array(results.prefix(maxResults))
    }
}

@MainActor
@Suite(.serialized)
struct FileSearchProviderTests {
    private static let homeDir = NSHomeDirectory()

    private static let sampleResults: [MDQuerySearch.FileResult] = [
        .init(path: homeDir + "/Documents/readme.md", name: "readme.md"),
        .init(path: homeDir + "/Projects/readme.txt", name: "readme.txt"),
        .init(path: homeDir + "/Desktop/notes.md", name: "notes.md"),
    ]

    // MARK: - Short query

    @Test func singleCharQueryReturnsResults() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "a")
        #expect(!results.isEmpty)
    }

    @Test func emptyQueryReturnsEmpty() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "")
        #expect(results.isEmpty)
    }

    // MARK: - Basic results

    @Test func returnsResults() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        #expect(results.count == 3)
    }

    @Test func resultTypeIsFile() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        for result in results {
            #expect(result.resultType == .file)
        }
    }

    @Test func resultsHaveURL() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        for result in results {
            #expect(result.url != nil)
        }
    }

    // MARK: - Score ordering

    @Test func scoreDecreasesWithIndex() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        guard results.count >= 2 else {
            Issue.record("Expected at least 2 results")
            return
        }
        #expect(results[0].score > results[1].score)
    }

    // MARK: - Path shortening

    @Test func subtitleUsesTildeForHomeDir() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        guard let first = results.first else {
            Issue.record("Expected results")
            return
        }
        #expect(first.subtitle.hasPrefix("~"))
        #expect(!first.subtitle.hasPrefix(Self.homeDir))
    }

    @Test func subtitleShowsParentDirectory() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        guard let first = results.first else {
            Issue.record("Expected results")
            return
        }
        #expect(first.subtitle == "~/Documents")
    }

    // MARK: - Modifier actions

    @Test func hasCommandModifierAction() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        guard let first = results.first else {
            Issue.record("Expected results")
            return
        }
        #expect(first.modifierActions[.command] != nil)
        #expect(first.modifierActions[.command]?.subtitle == "Reveal in Finder")
    }

    // MARK: - Empty results

    @Test func emptyMDQueryReturnsEmpty() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: []))
        let results = await provider.search(query: "readme")
        #expect(results.isEmpty)
    }

    // MARK: - Hidden file detection

    @Test func dotPrefixQuerySetsIncludeHidden() async {
        let capturing = CapturingMDQuery()
        let provider = FileSearchProvider(searcher: capturing)
        _ = await provider.search(query: ".gitignore")
        #expect(capturing.lastIncludeHidden == true)
    }

    @Test func normalQueryDoesNotIncludeHidden() async {
        let capturing = CapturingMDQuery()
        let provider = FileSearchProvider(searcher: capturing)
        _ = await provider.search(query: "readme")
        #expect(capturing.lastIncludeHidden == false)
    }

    // MARK: - Content type filtering

    @Test func fileProviderExcludesFolders() async {
        let capturing = CapturingMDQuery()
        let provider = FileSearchProvider(searcher: capturing, contentType: .excludeFolders)
        _ = await provider.search(query: "readme")
        if case .exclude(let type) = capturing.lastContentType {
            #expect(type == "public.folder")
        } else {
            Issue.record("Expected .exclude content type")
        }
    }

    @Test func folderProviderOnlyFolders() async {
        let capturing = CapturingMDQuery()
        let provider = FileSearchProvider(searcher: capturing, contentType: .foldersOnly)
        _ = await provider.search(query: "docs")
        if case .only(let type) = capturing.lastContentType {
            #expect(type == "public.folder")
        } else {
            Issue.record("Expected .only content type")
        }
    }

    @Test func defaultProviderUsesAnyContentType() async {
        let capturing = CapturingMDQuery()
        let provider = FileSearchProvider(searcher: capturing)
        _ = await provider.search(query: "readme")
        if case .any = capturing.lastContentType {
        } else {
            Issue.record("Expected .any content type")
        }
    }

    // MARK: - Result count limit

    @Test func resultsLimitedToMaxResults() async {
        var many: [MDQuerySearch.FileResult] = []
        for i in 0..<30 {
            many.append(.init(path: Self.homeDir + "/file\(i).txt", name: "file\(i).txt"))
        }
        let provider = FileSearchProvider(searcher: MockMDQuery(results: many))
        let results = await provider.search(query: "file")
        #expect(results.count == FileSearchProvider.maxResults)
    }

    // MARK: - Name display

    @Test func nameIsFileName() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        guard let first = results.first else {
            Issue.record("Expected results")
            return
        }
        #expect(first.name == "readme.md")
    }

    // MARK: - itemId

    @Test func itemIdIsFilePath() async {
        let provider = FileSearchProvider(searcher: MockMDQuery(results: Self.sampleResults))
        let results = await provider.search(query: "readme")
        guard let first = results.first else {
            Issue.record("Expected results")
            return
        }
        #expect(first.itemId == Self.homeDir + "/Documents/readme.md")
    }
}

// MARK: - MDQuerySearch pure function tests

struct MDQuerySearchTests {
    // MARK: - escapeQuery

    @Test func escapeBackslash() {
        #expect(MDQuerySearch.escapeQuery("a\\b") == "a\\\\b")
    }

    @Test func escapeQuote() {
        #expect(MDQuerySearch.escapeQuery("a\"b") == "a\\\"b")
    }

    @Test func escapeAsterisk() {
        #expect(MDQuerySearch.escapeQuery("a*b") == "a\\*b")
    }

    @Test func escapeEmpty() {
        #expect(MDQuerySearch.escapeQuery("") == "")
    }

    @Test func escapeNormal() {
        #expect(MDQuerySearch.escapeQuery("readme") == "readme")
    }

    @Test func escapeMultipleSpecialChars() {
        #expect(MDQuerySearch.escapeQuery("a\\\"*b") == "a\\\\\\\"\\*b")
    }

    // MARK: - buildQueryString

    @Test func buildQueryStringAny() {
        let qs = MDQuerySearch.buildQueryString(name: "readme", contentType: .any)
        #expect(qs == "kMDItemFSName == \"*readme*\"cd")
    }

    @Test func buildQueryStringOnlyFolder() {
        let qs = MDQuerySearch.buildQueryString(name: "docs", contentType: .foldersOnly)
        #expect(qs == "kMDItemFSName == \"*docs*\"cd && kMDItemContentType == \"public.folder\"")
    }

    @Test func buildQueryStringExcludeFolder() {
        let qs = MDQuerySearch.buildQueryString(name: "readme", contentType: .excludeFolders)
        #expect(qs == "kMDItemFSName == \"*readme*\"cd && kMDItemContentType != \"public.folder\"")
    }

    @Test func buildQueryStringEscapesSpecialChars() {
        let qs = MDQuerySearch.buildQueryString(name: "a\"b", contentType: .any)
        #expect(qs == "kMDItemFSName == \"*a\\\"b*\"cd")
    }

    // MARK: - isHiddenPath

    @Test func hiddenDirectory() {
        #expect(MDQuerySearch.isHiddenPath("/Users/test/.git/config") == true)
    }

    @Test func hiddenFile() {
        #expect(MDQuerySearch.isHiddenPath("/Users/test/.DS_Store") == true)
    }

    @Test func normalPath() {
        #expect(MDQuerySearch.isHiddenPath("/Users/test/Documents/readme.md") == false)
    }

    @Test func fileWithDotInName() {
        #expect(MDQuerySearch.isHiddenPath("/Users/test/file.txt") == false)
    }

    @Test func nestedHiddenDirectory() {
        #expect(MDQuerySearch.isHiddenPath("/Users/test/.config/settings.json") == true)
    }

    @Test func dotInMiddleOfComponent() {
        #expect(MDQuerySearch.isHiddenPath("/Users/test/my.project/file.txt") == false)
    }
}

// MARK: - SearchViewModel .file confirm test

@MainActor
struct FileConfirmTests {
    @Test func confirmOpensFileWithDefaultApp() async {
        let fileURL = URL(fileURLWithPath: "/Users/test/document.pdf")
        let provider = StubSearchProvider(results: [
            SearchResult(
                itemId: fileURL.path, icon: nil, name: "document.pdf",
                subtitle: "~/document.pdf", resultType: .file,
                url: fileURL, score: 1.0
            ),
        ])
        let mockWorkspace = MockWorkspaceOpener()
        let router = SearchRouter(defaultProvider: provider)
        let vm = await SearchViewModel(router: router, workspace: mockWorkspace, debounceMilliseconds: 0)
        vm.query = "doc"
        await waitUntil { !vm.results.isEmpty }
        #expect(vm.confirm() == true)
        #expect(mockWorkspace.openedURLs == [fileURL])
    }
}
