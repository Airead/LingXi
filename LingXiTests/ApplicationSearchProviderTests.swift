import Foundation
import Testing
@testable import LingXi

@Suite(.serialized)
struct ApplicationSearchProviderTests {
    private static let provider: ApplicationSearchProvider = {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingXiTests-AppSearch")
        let fm = FileManager.default

        try? fm.removeItem(at: tempDir)
        try! fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        func createApp(_ name: String, bundleName: String? = nil, displayName: String? = nil) {
            let contentsDir = tempDir.appendingPathComponent("\(name).app/Contents")
            try! fm.createDirectory(at: contentsDir, withIntermediateDirectories: true)

            var plist: [String: Any] = [:]
            if let bundleName { plist["CFBundleName"] = bundleName }
            if let displayName { plist["CFBundleDisplayName"] = displayName }
            if !plist.isEmpty {
                let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try! data.write(to: contentsDir.appendingPathComponent("Info.plist"))
            }
        }

        createApp("Safari", displayName: "Safari")
        createApp("Terminal", bundleName: "Terminal")
        createApp("Calculator")
        createApp("System Settings", displayName: "System Settings")
        createApp(".HiddenApp")

        createApp("LinkTarget")
        try! fm.createSymbolicLink(
            at: tempDir.appendingPathComponent("LinkAlias.app"),
            withDestinationURL: tempDir.appendingPathComponent("LinkTarget.app")
        )

        return ApplicationSearchProvider(searchPaths: [tempDir.path])
    }()

    // MARK: - Tests

    @Test func emptyQueryReturnsEmpty() async {
        let results = await Self.provider.search(query: "")
        #expect(results.isEmpty)
    }

    @Test func findsByName() async {
        let results = await Self.provider.search(query: "Safari")
        #expect(results.contains { $0.name == "Safari" })
    }

    @Test func caseInsensitive() async {
        let results = await Self.provider.search(query: "safari")
        #expect(results.contains { $0.name == "Safari" })
    }

    @Test func invalidQueryReturnsEmpty() async {
        let results = await Self.provider.search(query: "zzzzxyznonexistent")
        #expect(results.isEmpty)
    }

    @Test func resultsHaveApplicationType() async {
        let results = await Self.provider.search(query: "Safari")
        for result in results {
            #expect(result.resultType == .application)
        }
    }

    @Test func resultsHaveURL() async {
        let results = await Self.provider.search(query: "Safari")
        for result in results {
            #expect(result.url != nil)
        }
    }

    @Test func prefixMatchScoresHigher() async {
        let results = await Self.provider.search(query: "Sys")
        guard let first = results.first else {
            Issue.record("Expected results for 'Sys'")
            return
        }
        #expect(first.score == SearchScore.prefixMatch)
    }

    @Test func hiddenAppsAreExcluded() async {
        let results = await Self.provider.search(query: "Hidden")
        #expect(results.isEmpty)
    }

    @Test func symlinkDeduplication() async {
        let results = await Self.provider.search(query: "Link")
        #expect(results.count == 1)
    }

    @Test func readsBundleDisplayName() async {
        let results = await Self.provider.search(query: "System Settings")
        #expect(results.contains { $0.name == "System Settings" })
    }

    @Test func readsBundleName() async {
        let results = await Self.provider.search(query: "Terminal")
        #expect(results.contains { $0.name == "Terminal" })
    }

    @Test func fallsBackToFileName() async {
        let results = await Self.provider.search(query: "Calculator")
        #expect(results.contains { $0.name == "Calculator" })
    }
}
