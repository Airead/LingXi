import Foundation
import Testing
@testable import LingXi

struct StubSearchProvider: SearchProvider {
    let results: [SearchResult]

    func search(query: String) async -> [SearchResult] {
        results
    }
}

final class MockWorkspaceOpener: WorkspaceOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

@MainActor
func waitUntil(timeout: Int = 1000, condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .milliseconds(timeout)
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 10 * 1_000_000)
    }
}
