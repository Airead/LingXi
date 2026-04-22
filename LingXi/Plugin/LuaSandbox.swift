import CLua

/// Applies a sandbox to a LuaState by removing dangerous functions.
nonisolated enum LuaSandbox {
    /// Apply sandbox restrictions. Call after `openLibs()`.
    static func apply(to state: LuaState) {
        for name in removedGlobals {
            state.removeGlobal(name)
        }
        for (table, fields) in removedFields {
            for field in fields {
                state.removeGlobalField(table: table, field: field)
            }
        }
    }

    /// Restrict `package.path` to the plugin's own directory.
    /// Call after `apply(to:)` and before loading the plugin script.
    static func setupPackagePath(to state: LuaState, pluginDir: String) {
        let path = "\(pluginDir)/?.lua;\(pluginDir)/?/init.lua"
        state.getGlobal("package")
        guard state.isTable(at: -1) else {
            state.pop()
            return
        }
        state.push(path)
        state.setField("path", at: -2)
        state.pop()
    }

    private static let removedGlobals = [
        "dofile",      // Load and execute arbitrary files
        "loadfile",    // Load arbitrary files as chunks
        "load",        // Load arbitrary strings/bytecode as chunks
        "debug",       // Debug library allows sandbox escape
    ]

    private static let removedFields: [(String, [String])] = [
        ("os", [
            "execute",   // Run shell commands
            "exit",      // Terminate the process
            "remove",    // Delete files
            "rename",    // Rename/move files
            "tmpname",   // Predictable temp file names
            "setlocale", // Modify process locale
            "getenv",    // Read environment variables
        ]),
        ("io", [
            "open",      // Open arbitrary files
            "popen",     // Run shell commands
            "input",     // Change default input
            "output",    // Change default output
            "tmpfile",   // Create temp files
            "close",     // Close file handles
            "read",      // Read from default input
            "write",     // Write to default output
            "lines",     // Iterate lines from files
        ]),
        ("package", [
            "loadlib",   // Load native libraries
        ]),
    ]
}
