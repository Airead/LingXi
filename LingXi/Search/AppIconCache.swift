import AppKit

/// Icon cache intended to be used as a stored property inside an actor.
/// The owning actor provides thread safety.
final class AppIconCache {
    private var cache: [String: NSImage] = [:]

    func icon(for bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty else { return nil }
        if let cached = cache[bundleId] { return cached }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 32, height: 32)
        cache[bundleId] = icon
        return icon
    }
}
