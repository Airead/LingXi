import AppKit

protocol WorkspaceOpening {
    @discardableResult
    func open(_ url: URL) -> Bool

    func urlForApplication(withBundleIdentifier bundleId: String) -> URL?

    @discardableResult
    func open(_ urls: [URL], withApplicationAt appURL: URL) -> Bool
}

extension NSWorkspace: WorkspaceOpening {
    // NSWorkspace.open(_:withApplicationAt:configuration:) is async; fire-and-forget here
    // because urlForApplication already validates the app exists before this is called.
    func open(_ urls: [URL], withApplicationAt appURL: URL) -> Bool {
        Task { try? await open(urls, withApplicationAt: appURL, configuration: OpenConfiguration()) }
        return true
    }
}
