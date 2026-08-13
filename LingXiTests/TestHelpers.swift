import AppKit
import Foundation
import Testing
@testable import LingXi

struct StubSearchProvider: SearchProvider {
    let results: [SearchResult]
    var supportsPreview: Bool = false

    func search(query: String) async -> [SearchResult] {
        results
    }
}

final class MockWorkspaceOpener: WorkspaceOpening {
    private(set) var openedURLs: [URL] = []
    private(set) var openedWithApp: [(urls: [URL], appURL: URL)] = []
    var bundleURLs: [String: URL] = [:]

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }

    func urlForApplication(withBundleIdentifier bundleId: String) -> URL? {
        bundleURLs[bundleId]
    }

    func open(_ urls: [URL], withApplicationAt appURL: URL) -> Bool {
        openedWithApp.append((urls: urls, appURL: appURL))
        return true
    }
}

/// Create a test CGImage filled with a solid color.
func makeTestImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func makeTestTempDir(label: String = "LingXiTests") -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)_\(UUID().uuidString)")
    // Force-unwrap: directory creation must succeed in tests; silent failure hides bugs.
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Crash if the directory points to the production ClipboardStore image path.
func assertTestImageDirectory(_ dir: URL) {
    precondition(
        dir.standardizedFileURL != ClipboardStore.defaultImageDirectory.standardizedFileURL,
        "Test attempted to use production image directory: \(dir.path)"
    )
}

func writeTestPlugin(in dir: URL, name: String, toml: String = "", lua: String) throws {
    let pluginDir = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest = toml.isEmpty ? """
        [plugin]
        id = "test.\(name)"
        name = "\(name)"
    """ : toml

    try manifest.write(
        to: pluginDir.appendingPathComponent("plugin.toml"),
        atomically: true,
        encoding: .utf8
    )
    try lua.write(
        to: pluginDir.appendingPathComponent("plugin.lua"),
        atomically: true,
        encoding: .utf8
    )
}

@MainActor
func emptyRouter() -> SearchRouter {
    SearchRouter(defaultProvider: StubSearchProvider(results: []))
}

// MARK: - Plugin market fixtures

/// Write a "remote" plugin source (plugin.toml + plugin.lua) that can be
/// installed via its file:// manifest URL. Returns the manifest URL.
@discardableResult
func writeMarketSourcePlugin(in dir: URL, id: String, version: String) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let manifest = """
        [plugin]
        id = "\(id)"
        name = "\(id)"
        version = "\(version)"
        description = "Test plugin \(id)"
        files = ["plugin.lua"]
        """
    let manifestURL = dir.appendingPathComponent("plugin.toml")
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
    try "function search(query) return {} end"
        .write(to: dir.appendingPathComponent("plugin.lua"), atomically: true, encoding: .utf8)
    return manifestURL
}

/// Write a registry TOML file with a single plugin entry.
func writeRegistryTOML(to file: URL, id: String, version: String, sourceURL: URL) throws {
    let toml = """
        name = "Test Registry"
        url = "https://example.com/test"

        [[plugins]]
        id = "\(id)"
        name = "\(id)"
        version = "\(version)"
        author = "Tester"
        description = "Test plugin \(id)"
        source = "\(sourceURL.absoluteString)"
        """
    try toml.write(to: file, atomically: true, encoding: .utf8)
}

/// Write an installed plugin directory (plugin.toml + plugin.lua + install.toml).
func writeInstalledPlugin(in pluginsDir: URL, id: String, version: String, sourceURL: URL) throws {
    let pluginDir = pluginsDir.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try """
        [plugin]
        id = "\(id)"
        name = "\(id)"
        version = "\(version)"
        description = "Test plugin \(id)"
        """.write(to: pluginDir.appendingPathComponent("plugin.toml"), atomically: true, encoding: .utf8)
    try "function search(query) return {} end"
        .write(to: pluginDir.appendingPathComponent("plugin.lua"), atomically: true, encoding: .utf8)
    let installInfo = InstallInfo(
        sourceURL: sourceURL,
        installedVersion: version,
        installedAt: Date(),
        pinnedRef: ""
    )
    try InstallManifest.write(installInfo, to: pluginDir.appendingPathComponent("install.toml"))
}

@MainActor
func waitUntil(timeout: Int = 1000, condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .milliseconds(timeout)
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 10 * 1_000_000)
    }
}
