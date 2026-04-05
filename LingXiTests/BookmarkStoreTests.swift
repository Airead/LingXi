import Foundation
import Testing
@testable import LingXi

@Suite(.serialized)
struct BookmarkStoreTests {
    private static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingXiTests-Bookmarks-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Safari

    @Test func parsesSafariBookmarks() async {
        let plistPath = Self.tempDir.appendingPathComponent("SafariBookmarks.plist").path
        writeSafariPlist(to: plistPath, bookmarks: [
            ("GitHub", "https://github.com"),
            ("Apple", "https://apple.com"),
        ])

        let bookmarks = await loadSafariBookmarks(path: plistPath)
        #expect(bookmarks.count == 2)
        #expect(bookmarks[0].title == "GitHub")
        #expect(bookmarks[0].url.absoluteString == "https://github.com")
        #expect(bookmarks[0].browserBundleId == "com.apple.Safari")
        #expect(bookmarks[1].title == "Apple")
    }

    @Test func safariSkipsReadingList() async {
        let plistPath = Self.tempDir.appendingPathComponent("SafariRL.plist").path
        let plist: [String: Any] = [
            "Children": [
                [
                    "Title": "com.apple.ReadingList",
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Children": [
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://reading.example.com",
                            "URIDictionary": ["title": "Reading Item"],
                        ] as [String : Any],
                    ],
                ] as [String : Any],
                [
                    "Title": "BookmarksBar",
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Children": [
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://real.example.com",
                            "URIDictionary": ["title": "Real Bookmark"],
                        ] as [String : Any],
                    ],
                ] as [String : Any],
            ],
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try! data.write(to: URL(fileURLWithPath: plistPath))

        let bookmarks = await loadSafariBookmarks(path: plistPath)
        #expect(bookmarks.count == 1)
        #expect(bookmarks[0].title == "Real Bookmark")
    }

    @Test func safariMissingFileReturnsEmpty() async {
        let bookmarks = await loadSafariBookmarks(path: "/nonexistent/path/Bookmarks.plist")
        #expect(bookmarks.isEmpty)
    }

    // MARK: - Chrome

    @Test func parsesChromeBookmarks() async {
        let profileDir = Self.tempDir.appendingPathComponent("ChromeTest/Default")
        try! FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let bookmarksFile = profileDir.appendingPathComponent("Bookmarks")
        writeChromeJSON(to: bookmarksFile.path, bookmarks: [
            ("Stack Overflow", "https://stackoverflow.com"),
            ("Rust Lang", "https://rust-lang.org"),
        ])

        let bookmarks = await loadChromeBookmarks(baseDir: Self.tempDir.appendingPathComponent("ChromeTest").path)
        #expect(bookmarks.count == 2)
        #expect(bookmarks[0].title == "Stack Overflow")
        #expect(bookmarks[0].url.absoluteString == "https://stackoverflow.com")
        #expect(bookmarks[0].browserBundleId == "com.google.Chrome")
    }

    @Test func chromeMultipleProfiles() async {
        let base = Self.tempDir.appendingPathComponent("ChromeMulti")
        let profile1 = base.appendingPathComponent("Default")
        let profile2 = base.appendingPathComponent("Profile 1")
        try! FileManager.default.createDirectory(at: profile1, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: profile2, withIntermediateDirectories: true)

        writeChromeJSON(to: profile1.appendingPathComponent("Bookmarks").path, bookmarks: [
            ("Site A", "https://a.example.com"),
        ])
        writeChromeJSON(to: profile2.appendingPathComponent("Bookmarks").path, bookmarks: [
            ("Site B", "https://b.example.com"),
        ])

        let bookmarks = await loadChromeBookmarks(baseDir: base.path)
        #expect(bookmarks.count == 2)
        let titles = Set(bookmarks.map(\.title))
        #expect(titles.contains("Site A"))
        #expect(titles.contains("Site B"))
    }

    @Test func chromeMissingDirReturnsEmpty() async {
        let bookmarks = await loadChromeBookmarks(baseDir: "/nonexistent/chrome/dir")
        #expect(bookmarks.isEmpty)
    }

    // MARK: - Dedup

    @Test func deduplicatesByURL() async {
        let plistPath = Self.tempDir.appendingPathComponent("SafariDedup.plist").path
        writeSafariPlist(to: plistPath, bookmarks: [
            ("GitHub", "https://github.com"),
            ("GitHub Mirror", "https://github.com"),
        ])

        let store = BookmarkStore(safariPath: plistPath)
        let bookmarks = await store.bookmarks
        #expect(bookmarks.count == 1)
        #expect(bookmarks[0].title == "GitHub")
    }

    // MARK: - Helpers

    private func writeSafariPlist(to path: String, bookmarks: [(String, String)]) {
        let children: [[String: Any]] = bookmarks.map { title, urlString in
            [
                "WebBookmarkType": "WebBookmarkTypeLeaf",
                "URLString": urlString,
                "URIDictionary": ["title": title],
            ] as [String: Any]
        }
        let plist: [String: Any] = [
            "Children": [
                [
                    "Title": "BookmarksBar",
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Children": children,
                ] as [String : Any],
            ],
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try! data.write(to: URL(fileURLWithPath: path))
    }

    private func writeChromeJSON(to path: String, bookmarks: [(String, String)]) {
        let children: [[String: Any]] = bookmarks.map { name, url in
            ["type": "url", "name": name, "url": url]
        }
        let json: [String: Any] = [
            "roots": [
                "bookmark_bar": [
                    "type": "folder",
                    "name": "Bookmarks Bar",
                    "children": children,
                ] as [String : Any],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: URL(fileURLWithPath: path))
    }

    private func loadSafariBookmarks(path: String) async -> [Bookmark] {
        let store = BookmarkStore(safariPath: path)
        return await store.bookmarks.filter { $0.browserBundleId == "com.apple.Safari" }
    }

    private func loadChromeBookmarks(baseDir: String) async -> [Bookmark] {
        let browser = ChromiumBrowser(bundleId: "com.google.Chrome", baseDir: baseDir)
        let store = BookmarkStore(safariPath: "/no-such-file", chromiumBrowsers: [browser])
        return await store.bookmarks.filter { $0.browserBundleId == "com.google.Chrome" }
    }
}
