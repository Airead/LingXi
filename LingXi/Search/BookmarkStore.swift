import Foundation

struct Bookmark: Sendable {
    let title: String
    let url: URL
    let browserBundleId: String

    var searchableFields: [String] {
        [title, url.host ?? "", url.absoluteString]
    }
}

struct ChromiumBrowser: Sendable {
    let bundleId: String
    let baseDir: String

    static let defaultBrowsers: [ChromiumBrowser] = {
        let appSupport = NSHomeDirectory() + "/Library/Application Support"
        return [
            ChromiumBrowser(bundleId: "com.google.Chrome",
                            baseDir: appSupport + "/Google/Chrome"),
            ChromiumBrowser(bundleId: "com.microsoft.edgemac",
                            baseDir: appSupport + "/Microsoft Edge"),
            ChromiumBrowser(bundleId: "com.brave.Browser",
                            baseDir: appSupport + "/BraveSoftware/Brave-Browser"),
            ChromiumBrowser(bundleId: "company.thebrowser.Browser",
                            baseDir: appSupport + "/Arc/User Data"),
        ]
    }()
}

final class BookmarkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedBookmarks: [Bookmark] = []
    private var fileSources: [DispatchSourceFileSystemObject] = []

    private let safariPath: String
    private let chromiumBrowsers: [ChromiumBrowser]

    private let watchQueue = DispatchQueue(label: "io.github.airead.lingxi.bookmarkwatch")
    private var pendingReload: DispatchWorkItem?

    static let defaultSafariPath: String = {
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
    }()

    convenience init() {
        self.init(safariPath: Self.defaultSafariPath, chromiumBrowsers: ChromiumBrowser.defaultBrowsers, watch: true)
    }

    init(safariPath: String, chromiumBrowsers: [ChromiumBrowser] = [], watch: Bool = false) {
        self.safariPath = safariPath
        self.chromiumBrowsers = chromiumBrowsers
        reload()
        if watch {
            startWatching()
        }
    }

    deinit {
        for source in fileSources {
            source.cancel()
        }
    }

    var bookmarks: [Bookmark] {
        lock.lock()
        defer { lock.unlock() }
        return cachedBookmarks
    }

    func reload() {
        var all: [Bookmark] = []
        all.append(contentsOf: loadSafariBookmarks())
        for browser in chromiumBrowsers {
            all.append(contentsOf: loadChromiumBookmarks(browser: browser))
        }
        all = dedup(all)

        lock.lock()
        cachedBookmarks = all
        lock.unlock()
    }

    // MARK: - Safari

    private func loadSafariBookmarks() -> [Bookmark] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: safariPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let children = plist["Children"] as? [[String: Any]]
        else { return [] }

        var results: [Bookmark] = []
        for child in children {
            if let title = child["Title"] as? String, title == "com.apple.ReadingList" {
                continue
            }
            collectSafariBookmarks(from: child, into: &results)
        }
        return results
    }

    private func collectSafariBookmarks(from node: [String: Any], into results: inout [Bookmark]) {
        let type = node["WebBookmarkType"] as? String

        if type == "WebBookmarkTypeLeaf",
           let urlString = node["URLString"] as? String,
           let url = URL(string: urlString) {
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                ?? node["Title"] as? String
                ?? urlString
            results.append(Bookmark(
                title: title,
                url: url,
                browserBundleId: "com.apple.Safari"
            ))
        } else if type == "WebBookmarkTypeList",
                  let children = node["Children"] as? [[String: Any]] {
            for child in children {
                collectSafariBookmarks(from: child, into: &results)
            }
        }
    }

    // MARK: - Chromium (Chrome, Edge, Brave, Arc)

    private static let chromiumBookmarkFileNames = ["Bookmarks", "AccountBookmarks"]

    private static func isChromiumProfileDir(_ name: String) -> Bool {
        name == "Default" || name == "Guest Profile" || name == "System Profile" || name.hasPrefix("Profile ")
    }

    private func loadChromiumBookmarks(browser: ChromiumBrowser) -> [Bookmark] {
        let baseDir = browser.baseDir
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }

        var results: [Bookmark] = []
        for dirName in contents where Self.isChromiumProfileDir(dirName) {
            let profileDir = (baseDir as NSString).appendingPathComponent(dirName)
            for fileName in Self.chromiumBookmarkFileNames {
                let bookmarksFile = (profileDir as NSString).appendingPathComponent(fileName)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: bookmarksFile)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let roots = json["roots"] as? [String: Any]
                else { continue }

                for (_, value) in roots {
                    guard let node = value as? [String: Any] else { continue }
                    collectChromiumBookmarks(from: node, browser: browser, into: &results)
                }
            }
        }

        return results
    }

    private func collectChromiumBookmarks(from node: [String: Any], browser: ChromiumBrowser, into results: inout [Bookmark]) {
        let type = node["type"] as? String

        if type == "url",
           let urlString = node["url"] as? String,
           let url = URL(string: urlString) {
            let title = node["name"] as? String ?? urlString
            results.append(Bookmark(
                title: title,
                url: url,
                browserBundleId: browser.bundleId
            ))
        } else if type == "folder",
                  let children = node["children"] as? [[String: Any]] {
            for child in children {
                collectChromiumBookmarks(from: child, browser: browser, into: &results)
            }
        }
    }

    // MARK: - Dedup

    private func dedup(_ bookmarks: [Bookmark]) -> [Bookmark] {
        var seen = Set<String>()
        return bookmarks.filter { bookmark in
            var key = bookmark.url.absoluteString.lowercased()
            if key.hasSuffix("/") { key = String(key.dropLast()) }
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    // MARK: - File watching

    private func startWatching() {
        let fm = FileManager.default

        var paths: [String] = []
        if fm.fileExists(atPath: safariPath) {
            paths.append(safariPath)
        }
        for browser in chromiumBrowsers {
            guard let contents = try? fm.contentsOfDirectory(atPath: browser.baseDir) else { continue }
            for dirName in contents where Self.isChromiumProfileDir(dirName) {
                let profileDir = (browser.baseDir as NSString).appendingPathComponent(dirName)
                for fileName in Self.chromiumBookmarkFileNames {
                    let bookmarksFile = (profileDir as NSString).appendingPathComponent(fileName)
                    if fm.fileExists(atPath: bookmarksFile) {
                        paths.append(bookmarksFile)
                    }
                }
            }
        }

        for path in paths {
            guard let source = makeFileSource(path: path) else { continue }
            fileSources.append(source)
        }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        pendingReload = work
        watchQueue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func makeFileSource(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }
}
