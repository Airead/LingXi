import AppKit
import Foundation

/// A SearchProvider backed by a Lua plugin script.
/// Each instance owns its own LuaState; the actor serializes access.
actor LuaSearchProvider: SearchProvider {
    nonisolated static let idPrefix = "lua:"

    nonisolated let name: String
    nonisolated let pluginDir: URL

    nonisolated let debounceMilliseconds: Int
    nonisolated let timeoutMilliseconds: Int
    nonisolated var supportsPreview: Bool { false }

    private let state: LuaState
    private weak var panelContext: PanelContext?

    init(name: String, pluginDir: URL, state: LuaState, debounce: Int = 100, timeout: Int = 5000, panelContext: PanelContext? = nil) {
        self.name = name
        self.pluginDir = pluginDir
        self.debounceMilliseconds = debounce
        self.timeoutMilliseconds = timeout
        self.state = state
        self.panelContext = panelContext
    }

    func setPanelContext(_ context: PanelContext?) {
        self.panelContext = context
    }

    func search(query: String) async -> [SearchResult] {
        parseResults(query: query)
    }

    /// Execute a named Lua function with a string argument (used by plugin commands).
    func executeFunction(name functionName: String, args: String) {
        state.getGlobal(functionName)
        guard state.isFunction(at: -1) else {
            state.pop()
            DebugLog.log("[LuaPlugin:\(name)] function '\(functionName)' not found")
            return
        }
        state.push(args)
        do {
            try state.pcall(nargs: 1, nresults: 0)
        } catch {
            DebugLog.log("[LuaPlugin:\(name)] error calling '\(functionName)': \(error)")
        }
    }

    /// Dispatch an event to this plugin by calling a Lua function with a data table.
    /// First tries the specific handler (e.g. `on_clipboard_change`),
    /// then falls back to the generic `on_event(eventName, data)` handler.
    func dispatchEvent(name eventName: String, data: [String: String]) {
        let specificHandler = "on_" + eventName.replacingOccurrences(of: ".", with: "_")
        let handledSpecific = callLuaFunction(name: specificHandler, data: data)
        let handledGeneric = callLuaFunction(name: "on_event", eventName: eventName, data: data)
        if !handledSpecific && !handledGeneric {
            // No handler registered — silently ignore
        }
    }

    private func callLuaFunction(name functionName: String, data: [String: String]) -> Bool {
        state.getGlobal(functionName)
        guard state.isFunction(at: -1) else {
            state.pop()
            return false
        }
        state.createTable(nrec: Int32(data.count))
        for (key, value) in data {
            state.push(value)
            state.setField(key, at: -2)
        }
        do {
            try state.pcall(nargs: 1, nresults: 0)
            return true
        } catch {
            DebugLog.log("[LuaPlugin:\(name)] event '\(functionName)' error: \(error)")
            return true
        }
    }

    private func callLuaFunction(name functionName: String, eventName: String, data: [String: String]) -> Bool {
        state.getGlobal(functionName)
        guard state.isFunction(at: -1) else {
            state.pop()
            return false
        }
        state.push(eventName)
        state.createTable(nrec: Int32(data.count))
        for (key, value) in data {
            state.push(value)
            state.setField(key, at: -2)
        }
        do {
            try state.pcall(nargs: 2, nresults: 0)
            return true
        } catch {
            DebugLog.log("[LuaPlugin:\(name)] event '\(functionName)' error: \(error)")
            return true
        }
    }

    // MARK: - Private

    private func parseResults(query: String) -> [SearchResult] {
        state.getGlobal("search")
        guard state.isFunction(at: -1) else {
            state.pop()
            return []
        }

        state.push(query)
        do {
            try state.pcall(nargs: 1, nresults: 1)
        } catch {
            DebugLog.log("[LuaPlugin:\(name)] search error: \(error)")
            return [errorResult("\(error)")]
        }

        defer { state.pop() }

        guard state.isTable(at: -1) else { return [] }

        var results: [SearchResult] = []
        state.iterateArray(at: -1) {
            if let result = parseOneResult(at: -1) {
                results.append(result)
            }
        }
        return results
    }

    private func errorResult(_ message: String) -> SearchResult {
        SearchResult(
            itemId: "\(Self.idPrefix)\(name):error",
            icon: nil,
            name: "Plugin error: \(name)",
            subtitle: message,
            resultType: .command,
            url: nil,
            score: 100
        )
    }

    private func parseOneResult(at index: Int32) -> SearchResult? {
        guard state.isTable(at: index) else { return nil }

        let title = state.stringField("title", at: index) ?? ""
        guard !title.isEmpty else { return nil }

        let subtitle = state.stringField("subtitle", at: index) ?? ""
        let urlString = state.stringField("url", at: index)
        let score = state.numberField("score", at: index) ?? 50.0
        let url: URL? = urlString.flatMap { URL(string: $0) }
        let itemId = "\(Self.idPrefix)\(name):\(title)"
        let iconString = state.stringField("icon", at: index)
        let icon: NSImage? = iconString.flatMap { Self.imageFromString($0) }

        var result = SearchResult(
            itemId: itemId,
            icon: icon,
            name: title,
            subtitle: subtitle,
            resultType: .command,
            url: url,
            score: score
        )

        state.getField("action", at: index)
        if state.isFunction(at: -1) {
            let ref = state.ref(at: -1)
            result.action = { [weak self] _ in
                guard let self else { return false }
                Task {
                    await self.executeAction(ref: ref)
                }
                return true
            }
        } else {
            state.pop()
        }

        return result
    }

    private func executeAction(ref: Int32) {
        state.pushRef(ref)
        do {
            try state.pcall(nargs: 0, nresults: 0)
        } catch {
            DebugLog.log("[LuaPlugin:\(name)] error calling action ref \(ref): \(error)")
        }
    }

    // MARK: - Icon rendering

    /// Converts a string to an NSImage for use as a search result icon.
    /// Supports single emoji characters and base64-encoded SVG data URIs.
    /// Returns nil for empty strings.
    nonisolated static func imageFromString(_ string: String) -> NSImage? {
        guard !string.isEmpty else { return nil }

        if string.hasPrefix("data:image/svg+xml;base64,") {
            let base64String = String(string.dropFirst("data:image/svg+xml;base64,".count))
            guard let data = Data(base64Encoded: base64String) else { return nil }
            return NSImage(data: data)
        }

        // Treat as text (emoji or other character)
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.labelColor
        ]
        let attributedString = NSAttributedString(string: string, attributes: attributes)
        let textSize = attributedString.size()
        let point = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        )
        attributedString.draw(at: point)
        image.unlockFocus()
        return image
    }
}
