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

@MainActor
func waitUntil(timeout: Int = 1000, condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .milliseconds(timeout)
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 10 * 1_000_000)
    }
}
