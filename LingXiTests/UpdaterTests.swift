import Foundation
import Testing
@testable import LingXi

struct UpdaterTests {
    // MARK: - Version parsing

    @Test func parseVersionStandard() {
        #expect(UpdateController.parseVersion("v1.2.3") == [1, 2, 3])
        #expect(UpdateController.parseVersion("0.5") == [0, 5])
        #expect(UpdateController.parseVersion("V2.0.0") == [2, 0, 0])
        #expect(UpdateController.parseVersion(" v1.0 ") == [1, 0])
    }

    @Test func parseVersionRejectsInvalid() {
        #expect(UpdateController.parseVersion("invalid") == nil)
        #expect(UpdateController.parseVersion("") == nil)
        #expect(UpdateController.parseVersion("v") == nil)
        #expect(UpdateController.parseVersion("1.2.x") == nil)
    }

    @Test func isNewerComparesCorrectly() {
        #expect(UpdateController.isNewer("v1.2.4", than: "1.2.3"))
        #expect(UpdateController.isNewer("v1.3.0", than: "v1.2.99"))
        #expect(UpdateController.isNewer("v1.2.3.1", than: "1.2.3"))
        #expect(UpdateController.isNewer("v2.0", than: "1.99.99"))
    }

    @Test func isNewerReturnsFalseWhenSameOrOlder() {
        #expect(!UpdateController.isNewer("v1.2.3", than: "1.2.3"))
        #expect(!UpdateController.isNewer("v0.9", than: "1.0"))
        #expect(!UpdateController.isNewer("invalid", than: "1.0"))
        #expect(!UpdateController.isNewer("v1.0", than: "invalid"))
    }

    @Test func normalizeDisplayVersionAddsPrefix() {
        #expect(UpdateController.normalizeDisplayVersion("1.0.0") == "v1.0.0")
        #expect(UpdateController.normalizeDisplayVersion("v2.0") == "v2.0")
        #expect(UpdateController.normalizeDisplayVersion("V3") == "V3")
        #expect(UpdateController.normalizeDisplayVersion(" 1.2 ") == "v1.2")
    }

    // MARK: - DMG asset selection

    @Test func findDMGURLPrefersDMG() {
        let assets = [
            GitHubAsset(name: "LingXi-1.0.0-arm64.dmg", downloadURL: "https://example.com/dmg"),
            GitHubAsset(name: "LingXi-1.0.0.zip", downloadURL: "https://example.com/zip"),
        ]
        #expect(UpdateController.findDMGURL(assets)?.absoluteString == "https://example.com/dmg")
    }

    @Test func findDMGURLReturnsNilWhenAbsent() {
        let assets = [GitHubAsset(name: "x.zip", downloadURL: "https://example.com/zip")]
        #expect(UpdateController.findDMGURL(assets) == nil)
    }

    // MARK: - GitHub release JSON

    @Test func parseGitHubReleaseExtractsAssetsAndTag() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/Airead/LingXi/releases/tag/v0.2.0",
          "assets": [
            {"name": "LingXi-0.2.0-arm64.dmg", "browser_download_url": "https://example.com/dmg"}
          ]
        }
        """.data(using: .utf8)!
        let release = try GitHubReleaseData.parse(from: json)
        #expect(release.tagName == "v0.2.0")
        #expect(release.htmlURL.contains("Airead/LingXi"))
        #expect(release.assets.count == 1)
        #expect(release.assets.first?.name == "LingXi-0.2.0-arm64.dmg")
        #expect(release.assets.first?.downloadURL == "https://example.com/dmg")
    }

    @Test func parseGitHubReleaseHandlesMissingFields() throws {
        let json = "{}".data(using: .utf8)!
        let release = try GitHubReleaseData.parse(from: json)
        #expect(release.tagName == "")
        #expect(release.htmlURL == "")
        #expect(release.assets.isEmpty)
    }

    @Test func parseGitHubReleaseRejectsNonObject() {
        let json = "[]".data(using: .utf8)!
        #expect(throws: NSError.self) {
            _ = try GitHubReleaseData.parse(from: json)
        }
    }

    // MARK: - Staged app paths

    @Test func stagedPathDerivedFromAppURL() {
        let appURL = URL(fileURLWithPath: "/tmp/foo/LingXi.app")
        let staged = AppUpdater.stagedPath(appURL: appURL)
        #expect(staged.path == "/tmp/foo/.LingXi-update.app")
    }

    @Test func cleanupStagedAppRemovesIt() throws {
        let dir = makeTestTempDir(label: "Updater")
        let appPath = dir.appendingPathComponent("LingXi.app")
        try FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: true)
        let staged = AppUpdater.stagedPath(appURL: appPath)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        AppUpdater.cleanupStagedApp(appURL: appPath)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func cleanupStagedAppNoOpIfAbsent() {
        let dir = makeTestTempDir(label: "Updater")
        let appPath = dir.appendingPathComponent("LingXi.app")
        // Should not throw or crash when nothing is staged.
        AppUpdater.cleanupStagedApp(appURL: appPath)
        #expect(!FileManager.default.fileExists(atPath: AppUpdater.stagedPath(appURL: appPath).path))
    }

    @Test func getStagedAppPathReturnsNilWhenAbsent() throws {
        let dir = makeTestTempDir(label: "Updater")
        let appPath = dir.appendingPathComponent("LingXi.app")
        try FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: true)
        #expect(AppUpdater.getStagedAppPath(appURL: appPath) == nil)
    }

    @Test func getStagedAppPathReturnsURLWhenPresent() throws {
        let dir = makeTestTempDir(label: "Updater")
        let appPath = dir.appendingPathComponent("LingXi.app")
        try FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: true)
        let staged = AppUpdater.stagedPath(appURL: appPath)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        // Compare standardized paths: appendingPathComponent appends a trailing slash
        // once the directory exists on disk, so URL equality would differ.
        #expect(AppUpdater.getStagedAppPath(appURL: appPath)?.path == staged.path)
    }

    // MARK: - Info.plist version

    @Test func getAppVersionReadsInfoPlist() throws {
        let dir = makeTestTempDir(label: "Updater")
        let appPath = dir.appendingPathComponent("LingXi.app")
        let contents = appPath.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.2.3"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        #expect(AppUpdater.getAppVersion(appPath) == "1.2.3")
    }

    @Test func getAppVersionReturnsNilWhenMissing() {
        let dir = makeTestTempDir(label: "Updater")
        #expect(AppUpdater.getAppVersion(dir) == nil)
    }
}
