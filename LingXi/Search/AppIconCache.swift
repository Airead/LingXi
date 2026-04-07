import AppKit

/// Icon cache intended to be used as a stored property inside an actor.
/// The owning actor provides thread safety.
nonisolated final class AppIconCache {
    private static let iconSize = NSSize(width: 32, height: 32)

    private var bundleIdCache: [String: NSImage] = [:]
    private var pathCache: [String: NSImage] = [:]

    func icon(for bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty else { return nil }
        if let cached = bundleIdCache[bundleId] { return cached }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = Self.iconSize
        bundleIdCache[bundleId] = icon
        return icon
    }

    func icon(forFile path: String) -> NSImage {
        if let cached = pathCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = Self.iconSize
        pathCache[path] = icon
        return icon
    }

    /// Preload icons for the given file paths off the main actor.
    func preload(paths: [String]) async {
        let loaded = await Task.detached {
            paths.map { ($0, NSWorkspace.shared.icon(forFile: $0)) }
        }.value
        for (path, icon) in loaded {
            icon.size = Self.iconSize
            self.pathCache[path] = icon
        }
    }
}
