import AppKit

actor ClipboardHistoryProvider: SearchProvider {
    nonisolated let supportsPreview = true
    nonisolated static let itemIdPrefix = "clipboard:"
    nonisolated static let appItemIdPrefix = "clipboard:app:"
    private static let appPreviewRowLimit = 20

    nonisolated static func extractId(from itemId: String) -> Int? {
        guard itemId.hasPrefix(itemIdPrefix), !itemId.hasPrefix(appItemIdPrefix) else {
            return nil
        }
        return Int(itemId.dropFirst(itemIdPrefix.count))
    }

    nonisolated static func extractAppName(from itemId: String) -> String? {
        guard itemId.hasPrefix(appItemIdPrefix) else { return nil }
        return String(itemId.dropFirst(appItemIdPrefix.count))
    }

    private let store: ClipboardStore
    private let iconCache = AppIconCache()
    private let copyHandler: @MainActor @Sendable (Int) -> Void

    private var cachedEmptyResults: [SearchResult] = []
    private var cachedVersion: Int = -1

    init(store: ClipboardStore, copyHandler: @escaping @MainActor @Sendable (Int) -> Void = { _ in }) {
        self.store = store
        self.copyHandler = copyHandler
    }

    func tabComplete(rawQuery: String, strippedQuery: String, selectedItem: SearchResult) async -> String? {
        guard let app = Self.extractAppName(from: selectedItem.itemId) else { return nil }
        let providerPrefix = String(rawQuery.prefix(rawQuery.count - strippedQuery.count))
        return providerPrefix + "@\(app) "
    }

    func search(query: String) async -> [SearchResult] {
        let (items, version) = await store.itemsWithVersion()

        if Self.isAppSelectionMode(query) {
            let searchTerm = String(query.dropFirst())
            return appSelectionResults(items: items, searchTerm: searchTerm)
        }

        let knownApps = Self.uniqueSourceApps(in: items)
        let parsed = Self.parseQuery(query, knownApps: knownApps)
        if parsed.content.isEmpty && parsed.appFilter == nil {
            return emptyQueryResults(items: items, version: version)
        }
        return filteredResults(items: items, parsed: parsed)
    }

    /// App-selection mode is triggered when the query starts with `@` and no space
    /// has been typed after it yet (mirrors emoji-search's group-selection mode).
    nonisolated static func isAppSelectionMode(_ query: String) -> Bool {
        guard query.hasPrefix("@") else { return false }
        return !query.dropFirst().contains(" ")
    }

    private func emptyQueryResults(items: [ClipboardItem], version: Int) -> [SearchResult] {
        if version == cachedVersion, !cachedEmptyResults.isEmpty {
            return cachedEmptyResults
        }

        let results = items.map { makeResult(item: $0) }
        cachedEmptyResults = results
        cachedVersion = version
        return results
    }

    private func filteredResults(items: [ClipboardItem], parsed: ParsedQuery) -> [SearchResult] {
        let pool: [ClipboardItem]
        if let appFilter = parsed.appFilter {
            pool = Self.filterBySourceApp(items: items, appFilter: appFilter)
        } else {
            pool = items
        }

        if parsed.content.isEmpty {
            return pool.map { makeResult(item: $0) }
        }

        let scored = pool.compactMap { item -> (ClipboardItem, Double)? in
            guard let score = FuzzyMatch.matchFields(
                query: parsed.content,
                fields: Self.contentFields(for: item)
            ) else { return nil }
            return (item, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.timestamp > rhs.0.timestamp
        }

        return scored.map { item, score in
            var result = makeResult(item: item)
            result.score = score
            return result
        }
    }

    // MARK: - App selection mode

    private func appSelectionResults(items: [ClipboardItem], searchTerm: String) -> [SearchResult] {
        var grouped: [String: (bundleId: String, items: [ClipboardItem])] = [:]
        var order: [String] = []
        for item in items where !item.sourceApp.isEmpty {
            if grouped[item.sourceApp] == nil {
                grouped[item.sourceApp] = (bundleId: item.sourceBundleId, items: [])
                order.append(item.sourceApp)
            }
            grouped[item.sourceApp]?.items.append(item)
        }

        struct Candidate {
            let app: String
            let bundleId: String
            let items: [ClipboardItem]
            let score: Double
            let latest: TimeInterval
        }

        let candidates: [Candidate] = order.compactMap { app in
            guard let group = grouped[app] else { return nil }
            let latest = group.items.first?.timestamp ?? 0
            if searchTerm.isEmpty {
                return Candidate(app: app, bundleId: group.bundleId, items: group.items, score: 0, latest: latest)
            }
            guard let match = FuzzyMatch.match(query: searchTerm, text: app) else { return nil }
            return Candidate(app: app, bundleId: group.bundleId, items: group.items, score: match.score, latest: latest)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.latest > rhs.latest
        }

        return candidates.map {
            makeAppResult(app: $0.app, bundleId: $0.bundleId, items: $0.items, score: $0.score)
        }
    }

    private func makeAppResult(app: String, bundleId: String, items: [ClipboardItem], score: Double) -> SearchResult {
        let icon = iconCache.icon(for: bundleId)
        let subtitle = items.count == 1 ? "1 item" : "\(items.count) items"
        let preview = Self.buildAppPreview(app: app, items: items)
        return SearchResult(
            itemId: "\(Self.appItemIdPrefix)\(app)",
            icon: icon,
            name: app,
            subtitle: subtitle,
            resultType: .clipboard,
            url: nil,
            score: score,
            previewData: .text(preview),
            action: { _ in false }
        )
    }

    nonisolated static func buildAppPreview(app: String, items: [ClipboardItem]) -> String {
        let slice = items.prefix(appPreviewRowLimit)
        var lines: [String] = [app, ""]
        for (idx, item) in slice.enumerated() {
            let label: String
            switch item.contentType {
            case .text:
                label = truncatedPreview(item.textContent, maxLength: 80)
            case .image:
                label = "[Image \(item.imageWidth)×\(item.imageHeight)]"
            }
            lines.append("\(idx + 1). \(label)")
        }
        if items.count > appPreviewRowLimit {
            lines.append("…(+\(items.count - appPreviewRowLimit) more)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Query parsing

    struct ParsedQuery: Equatable {
        let content: String
        let appFilter: String?
    }

    /// Split a raw query into content and optional `@app` filter.
    ///
    /// The first `@` opens the app filter; it extends to the next `@` or end-of-string.
    /// Within that range, multi-word app names ("Google Chrome") are resolved via a
    /// progressively-longer-prefix match against `knownApps`: the longest prefix of
    /// tokens that exactly matches a known app wins, and remaining tokens fall back
    /// into `content`. If no prefix matches, the whole span is treated as a fuzzy
    /// app filter so partial input like `@tong` still works.
    nonisolated static func parseQuery(_ query: String, knownApps: [String] = []) -> ParsedQuery {
        guard let atIndex = query.firstIndex(of: "@") else {
            return ParsedQuery(
                content: query.trimmingCharacters(in: .whitespaces),
                appFilter: nil
            )
        }

        let before = String(query[..<atIndex])
        let afterAt = query[query.index(after: atIndex)...]
        let appEnd = afterAt.firstIndex(of: "@") ?? afterAt.endIndex
        let afterSpan = afterAt[..<appEnd].trimmingCharacters(in: .whitespaces)

        if afterSpan.isEmpty {
            return ParsedQuery(
                content: before.trimmingCharacters(in: .whitespaces),
                appFilter: nil
            )
        }

        let parts = afterSpan.split(separator: " ").map(String.init)
        let appsLower = Set(knownApps.map { $0.lowercased() })

        for i in stride(from: parts.count, through: 1, by: -1) {
            let candidate = parts.prefix(i).joined(separator: " ")
            if appsLower.contains(candidate.lowercased()) {
                let rest = parts.dropFirst(i).joined(separator: " ")
                let content = (before + " " + rest).trimmingCharacters(in: .whitespaces)
                return ParsedQuery(content: content, appFilter: candidate)
            }
        }

        return ParsedQuery(
            content: before.trimmingCharacters(in: .whitespaces),
            appFilter: afterSpan
        )
    }

    nonisolated static func uniqueSourceApps(in items: [ClipboardItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where !item.sourceApp.isEmpty {
            if seen.insert(item.sourceApp).inserted {
                result.append(item.sourceApp)
            }
        }
        return result
    }

    nonisolated static func filterBySourceApp(items: [ClipboardItem], appFilter: String) -> [ClipboardItem] {
        var seen = Set<String>()
        var uniqueApps: [String] = []
        for item in items where !item.sourceApp.isEmpty {
            if seen.insert(item.sourceApp).inserted {
                uniqueApps.append(item.sourceApp)
            }
        }

        var matchedApps = Set<String>()
        for app in uniqueApps {
            if FuzzyMatch.match(query: appFilter, text: app) != nil {
                matchedApps.insert(app)
            }
        }

        return items.filter { matchedApps.contains($0.sourceApp) }
    }

    nonisolated static func contentFields(for item: ClipboardItem) -> [String] {
        switch item.contentType {
        case .text:
            return [item.textContent]
        case .image:
            var fields = ["Image: \(item.imageWidth)×\(item.imageHeight)"]
            if !item.ocrText.isEmpty { fields.append(item.ocrText) }
            return fields
        }
    }

    private func makeResult(item: ClipboardItem) -> SearchResult {
        let name: String
        let icon: NSImage?
        let preview: PreviewData
        var thumbURL: URL?

        switch item.contentType {
        case .text:
            name = Self.truncatedPreview(item.textContent, maxLength: 80)
            icon = appIcon(for: item.sourceBundleId)
            preview = .text(item.textContent)
        case .image:
            name = "Image: \(item.imageWidth)×\(item.imageHeight) (\(Self.formattedSize(item.imageSize)))"
            icon = nil
            let imageURL = store.imageDirectory.appendingPathComponent(item.imagePath)
            let desc = "\(item.imageWidth)×\(item.imageHeight) · \(Self.formattedSize(item.imageSize))"
            preview = .image(path: imageURL, description: desc)
            thumbURL = imageURL
        }

        let subtitle = Self.buildSubtitle(sourceApp: item.sourceApp, timestamp: item.timestamp)
        let itemId = item.id
        let capturedHandler = copyHandler

        return SearchResult(
            itemId: "\(Self.itemIdPrefix)\(item.id)",
            icon: icon,
            name: name,
            subtitle: subtitle,
            resultType: .clipboard,
            url: nil,
            score: 0,
            previewData: preview,
            modifierActions: [
                .command: ModifierAction(subtitle: "Copy to Clipboard") { _ in
                    capturedHandler(itemId)
                    return true
                },
            ],
            thumbnailURL: thumbURL
        )
    }

    private func appIcon(for bundleId: String) -> NSImage? {
        iconCache.icon(for: bundleId)
    }

    nonisolated static func truncatedPreview(_ text: String, maxLength: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= maxLength { return singleLine }
        return String(singleLine.prefix(maxLength - 1)) + "…"
    }

    nonisolated static func relativeTime(from timestamp: TimeInterval) -> String {
        let delta = Date().timeIntervalSince1970 - timestamp
        switch delta {
        case ..<60:    return "just now"
        case ..<3600:  return "\(Int(delta / 60))m ago"
        case ..<86400: return "\(Int(delta / 3600))h ago"
        default:       return "\(Int(delta / 86400))d ago"
        }
    }

    nonisolated static func formattedSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    private nonisolated static func buildSubtitle(sourceApp: String, timestamp: TimeInterval) -> String {
        let time = relativeTime(from: timestamp)
        if sourceApp.isEmpty { return time }
        return "\(sourceApp) \(time)"
    }
}
