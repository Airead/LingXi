import Foundation
import Testing
@testable import LingXi

@MainActor
@Suite(.serialized)
struct BookmarkSearchProviderTests {
    private static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingXiTests-BmSearch-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let provider: BookmarkSearchProvider = {
        let plistPath = tempDir.appendingPathComponent("Bookmarks.plist").path
        let plist: [String: Any] = [
            "Children": [
                [
                    "Title": "BookmarksBar",
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Children": [
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://github.com",
                            "URIDictionary": ["title": "GitHub"],
                        ] as [String : Any],
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://stackoverflow.com",
                            "URIDictionary": ["title": "Stack Overflow"],
                        ] as [String : Any],
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://developer.apple.com",
                            "URIDictionary": ["title": "Apple Developer"],
                        ] as [String : Any],
                    ],
                ] as [String : Any],
            ],
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try! data.write(to: URL(fileURLWithPath: plistPath))

        let store = BookmarkStore(safariPath: plistPath)
        return BookmarkSearchProvider(store: store)
    }()

    @Test func emptyQueryReturnsEmpty() async {
        let results = await Self.provider.search(query: "")
        #expect(results.isEmpty)
    }

    @Test func findsByTitle() async {
        let results = await Self.provider.search(query: "GitHub")
        #expect(results.contains { $0.name == "GitHub" })
    }

    @Test func findsByURL() async {
        let results = await Self.provider.search(query: "stackoverflow")
        #expect(results.contains { $0.name == "Stack Overflow" })
    }

    @Test func caseInsensitive() async {
        let results = await Self.provider.search(query: "github")
        #expect(results.contains { $0.name == "GitHub" })
    }

    @Test func resultsHaveBookmarkType() async {
        let results = await Self.provider.search(query: "GitHub")
        for result in results {
            #expect(result.resultType == .bookmark)
        }
    }

    @Test func resultsHaveURL() async {
        let results = await Self.provider.search(query: "GitHub")
        for result in results {
            #expect(result.url != nil)
        }
    }

    @Test func resultsHaveOpenWithBundleId() async {
        let results = await Self.provider.search(query: "GitHub")
        guard let github = results.first(where: { $0.name == "GitHub" }) else {
            Issue.record("Expected GitHub result")
            return
        }
        #expect(github.openWithBundleId == "com.apple.Safari")
    }

    @Test func noMatchReturnsEmpty() async {
        let results = await Self.provider.search(query: "zzzznonexistent")
        #expect(results.isEmpty)
    }

    @Test func fuzzyMatchByDomain() async {
        // "apple" should match "developer.apple.com" in URL
        let results = await Self.provider.search(query: "apple")
        #expect(results.contains { $0.name == "Apple Developer" })
    }

    @Test func subtitleIsURL() async {
        let results = await Self.provider.search(query: "GitHub")
        guard let github = results.first(where: { $0.name == "GitHub" }) else {
            Issue.record("Expected GitHub result")
            return
        }
        #expect(github.subtitle == "https://github.com")
    }
}
