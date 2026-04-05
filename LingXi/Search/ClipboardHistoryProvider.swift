import AppKit

actor ClipboardHistoryProvider: SearchProvider {
    nonisolated static let itemIdPrefix = "clipboard:"

    nonisolated static func extractId(from itemId: String) -> Int? {
        guard itemId.hasPrefix(itemIdPrefix) else { return nil }
        return Int(itemId.dropFirst(itemIdPrefix.count))
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

    func search(query: String) async -> [SearchResult] {
        let (items, version) = await store.itemsWithVersion()
        if query.isEmpty {
            return emptyQueryResults(items: items, version: version)
        }
        return fuzzySearchResults(items: items, query: query)
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

    private func fuzzySearchResults(items: [ClipboardItem], query: String) -> [SearchResult] {
        scoredItems(from: items, query: query, names: { item in
            switch item.contentType {
            case .text:
                return [item.textContent, item.sourceApp]
            case .image:
                var fields = ["Image: \(item.imageWidth)×\(item.imageHeight)", item.sourceApp]
                if !item.ocrText.isEmpty { fields.append(item.ocrText) }
                return fields
            }
        }).map { item, score in
            var result = makeResult(item: item)
            result.score = score
            return result
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
            let imageURL = ClipboardStore.imageDirectory.appendingPathComponent(item.imagePath)
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
