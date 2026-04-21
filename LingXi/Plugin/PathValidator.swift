import Foundation

/// Validates file-system paths against a whitelist of allowed directories.
/// Prevents directory-traversal attacks by resolving symlinks and checking
/// that the canonical path is within an allowed prefix.
nonisolated struct PathValidator: Sendable {
    let allowedPaths: [String]

    /// Create a validator with a list of allowed path patterns.
    /// Patterns may contain `~` which is expanded to the user's home directory.
    init(allowedPaths: [String]) {
        self.allowedPaths = allowedPaths.map { PathValidator.expandPath($0) }
    }

    /// Check whether `path` is inside one of the allowed directories.
    /// Returns the canonical path if allowed, or `nil` if denied.
    func validate(_ path: String) -> String? {
        let expanded = PathValidator.expandPath(path)
        guard let canonical = canonicalPath(expanded) else {
            return nil
        }

        for allowed in allowedPaths {
            guard let allowedCanonical = canonicalPath(allowed) else { continue }
            if canonical.hasPrefix(allowedCanonical + "/") || canonical == allowedCanonical {
                return canonical
            }
        }

        DebugLog.log("[PathValidator] Denied access to: \(canonical)")
        return nil
    }

    /// Expand `~` to the user's home directory.
    private static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + String(path.dropFirst(1))
        }
        return path
    }

    /// Resolve symlinks and standardize the path.
    private func canonicalPath(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let resolved = try? url.resolvingSymlinksInPath().standardizedFileURL else {
            return nil
        }
        return resolved.path
    }
}
