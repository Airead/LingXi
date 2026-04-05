import AppKit
import Foundation

/// A single snippet parsed from a file.
struct Snippet: Sendable {
    let name: String
    let keyword: String
    let content: String
    let category: String
    let filePath: String
    let autoExpand: Bool
    let raw: Bool
    let isRandom: Bool
    let variants: [String]

    /// Display content for preview: joins variants with separator headers.
    var previewContent: String {
        guard isRandom, variants.count > 1 else { return content }
        return variants.enumerated().map { i, v in
            "── Variant \(i + 1) ──\n\(v)"
        }.joined(separator: "\n")
    }

    /// Resolve content, expanding placeholders unless raw.
    func resolvedContent() -> String {
        let text = isRandom ? (variants.randomElement() ?? content) : content
        guard !raw else { return text }
        let clip = NSPasteboard.general.string(forType: .string)
        return SnippetStore.expandPlaceholders(text, clipboard: clip)
    }
}

/// Directory-based snippet storage with YAML frontmatter parsing.
///
/// Each snippet is a `.md` or `.txt` file. Subdirectories act as categories.
/// Optional YAML frontmatter holds keyword and options.
actor SnippetStore {
    static let defaultDirectory: URL = {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/LingXi/snippets")
        return config
    }()

    nonisolated private static let supportedExtensions: Set<String> = ["md", "txt"]

    private let directory: URL
    private var snippets: [Snippet] = []
    private var cachedMtime: TimeInterval = 0
    private var hasLoaded = false

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    // MARK: - Public API

    func allSnippets() -> [Snippet] {
        ensureLoaded()
        return snippets
    }

    func findByKeyword(_ keyword: String) -> Snippet? {
        ensureLoaded()
        return snippets.first { $0.keyword == keyword }
    }

    /// Find a snippet by composite ID ("category/name" or "name").
    func findById(_ compositeId: String) -> Snippet? {
        ensureLoaded()
        let parts = compositeId.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            let category = String(parts[0])
            let name = String(parts[1])
            return snippets.first { $0.name == name && $0.category == category }
        }
        return snippets.first { $0.name == compositeId && $0.category.isEmpty }
    }

    @discardableResult
    func add(
        name: String,
        keyword: String,
        content: String,
        category: String = "",
        autoExpand: Bool = true,
        raw: Bool = false,
        isRandom: Bool = false,
        variants: [String]? = nil
    ) -> Bool {
        ensureLoaded()

        if !keyword.isEmpty, snippets.contains(where: { $0.keyword == keyword }) {
            return false
        }

        let safeName = Self.sanitizeFilename(name)
        let actualVariants = isRandom ? (variants ?? [content]) : []
        return persistSnippet(
            safeName: safeName, keyword: keyword, content: content,
            category: category, autoExpand: autoExpand, raw: raw,
            isRandom: isRandom, variants: actualVariants
        )
    }

    @discardableResult
    func remove(name: String, category: String = "") -> Bool {
        ensureLoaded()
        guard let index = snippets.firstIndex(where: { $0.name == name && $0.category == category }) else {
            return false
        }
        let filePath = snippets[index].filePath
        Self.trashFile(at: filePath)
        snippets.remove(at: index)
        return true
    }

    /// Validation errors for new snippet creation.
    enum ValidationError: Error, Equatable {
        case fileExists(name: String)
        case keywordInUse(keyword: String)
        case contentDuplicates(label: String)
        case writeFailed
    }

    /// Validate and add a new snippet atomically in a single actor hop.
    func validateAndAdd(
        name: String, category: String, keyword: String, content: String
    ) -> Result<Void, ValidationError> {
        ensureLoaded()
        let safeName = Self.sanitizeFilename(name)
        var duplicateLabel: String?
        for s in snippets {
            if s.name == safeName && s.category == category {
                return .failure(.fileExists(name: safeName))
            }
            if !keyword.isEmpty && s.keyword == keyword {
                return .failure(.keywordInUse(keyword: keyword))
            }
            if !content.isEmpty && duplicateLabel == nil && s.content == content {
                duplicateLabel = s.category.isEmpty ? s.name : "\(s.category)/\(s.name)"
            }
        }
        if let label = duplicateLabel {
            return .failure(.contentDuplicates(label: label))
        }

        guard persistSnippet(
            safeName: safeName, keyword: keyword, content: content,
            category: category, autoExpand: true, raw: false,
            isRandom: false, variants: []
        ) else {
            return .failure(.writeFailed)
        }
        return .success(())
    }

    func reload() {
        snippets = []
        cachedMtime = 0
        hasLoaded = false
        ensureLoaded()
    }

    // MARK: - Loading

    private func ensureLoaded() {
        let (currentMtime, fileURLs) = collectFileURLsAndMtime()
        if hasLoaded, currentMtime == cachedMtime {
            return
        }
        scanFiles(fileURLs)
        cachedMtime = currentMtime
        hasLoaded = true
    }

    /// Single-pass directory traversal that returns both the max mtime and all snippet file URLs.
    private func collectFileURLsAndMtime() -> (TimeInterval, [URL]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return (0, []) }

        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return (0, []) }

        let dirMtime = (try? directory.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? 0
        var maxMtime = dirMtime
        var fileURLs: [URL] = []
        let supportedExtensions = SnippetStore.supportedExtensions

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            if let mt = values?.contentModificationDate?.timeIntervalSince1970, mt > maxMtime {
                maxMtime = mt
            }
            let isDir = values?.isDirectory ?? false
            if !isDir, supportedExtensions.contains(url.pathExtension.lowercased()) {
                fileURLs.append(url)
            }
        }
        return (maxMtime, fileURLs)
    }

    private func scanFiles(_ fileURLs: [URL]) {
        snippets = []
        let resolvedDir = directory.standardizedFileURL.path

        for fileURL in fileURLs {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let relDir = fileURL.deletingLastPathComponent().standardizedFileURL.path
                .replacingOccurrences(of: resolvedDir, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let baseName = fileURL.deletingPathExtension().lastPathComponent

            let (meta, body) = Self.parseFrontmatter(text)
            let autoExpand = Self.boolValue(meta["auto_expand"], default: true)
            let raw = Self.boolValue(meta["raw"], default: false)

            // Multi-snippet format
            if let snippetsList = meta["snippets"] as? [[String: Any]] {
                for entry in snippetsList {
                    let kw = (entry["keyword"] as? String) ?? ""
                    let ct = (entry["content"] as? String)?.trimmingTrailingNewlines() ?? ""
                    let nm = (entry["name"] as? String) ?? kw.nonEmpty ?? baseName
                    let entryRaw = Self.boolValue(entry["raw"], default: raw)
                    let entryAE: Bool
                    if let ae = entry["auto_expand"] {
                        entryAE = Self.boolValue(ae, default: true)
                    } else {
                        entryAE = autoExpand
                    }
                    snippets.append(Snippet(
                        name: nm, keyword: kw, content: ct,
                        category: relDir, filePath: fileURL.path,
                        autoExpand: entryAE, raw: entryRaw,
                        isRandom: false, variants: []
                    ))
                }
            }

            // Single-snippet format
            let hasKeyword = (meta["keyword"] as? String) != nil
            let hasBody = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSnippetsList = meta["snippets"] != nil
            if hasKeyword || (hasBody && !hasSnippetsList) {
                let isRandom = Self.boolValue(meta["random"], default: false)
                let snippetBody = body.trimmingTrailingNewlines()

                let variants: [String]
                let displayContent: String
                if isRandom {
                    variants = Self.splitRandomSections(snippetBody)
                    displayContent = variants.joined(separator: "\n\n")
                } else {
                    variants = []
                    displayContent = snippetBody
                }

                snippets.append(Snippet(
                    name: baseName,
                    keyword: (meta["keyword"] as? String) ?? "",
                    content: displayContent,
                    category: relDir, filePath: fileURL.path,
                    autoExpand: autoExpand, raw: raw,
                    isRandom: isRandom, variants: variants
                ))
            }
        }
    }

    // MARK: - Frontmatter parsing (hand-written, no YAML dependency)

    /// Parse optional YAML frontmatter from text.
    /// Returns (metadata, body). If no frontmatter, returns (empty, full text).
    static func parseFrontmatter(_ text: String) -> ([String: Any], String) {
        guard text.hasPrefix("---") else { return ([:], text) }

        // Find closing ---
        guard let endRange = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return ([:], text)
        }

        let header = String(text[text.index(text.startIndex, offsetBy: 3)..<endRange.lowerBound])
        var body = String(text[endRange.upperBound...])
        if body.hasPrefix("\n") {
            body = String(body.dropFirst())
        }

        let meta = parseSimpleYAML(header)
        return (meta, body)
    }

    /// Minimal YAML parser supporting the snippet frontmatter subset:
    /// - Top-level key: value pairs
    /// - Quoted and unquoted string values
    /// - Boolean values (true/false)
    /// - A "snippets" list of dictionaries
    static func parseSimpleYAML(_ yaml: String) -> [String: Any] {
        var result: [String: Any] = [:]
        let lines = yaml.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            guard let colonIndex = trimmed.firstIndex(of: ":") else {
                i += 1
                continue
            }

            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let valueStr = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            if key == "snippets" && valueStr.isEmpty {
                // Parse list of dicts
                var snippetsList: [[String: Any]] = []
                i += 1
                while i < lines.count {
                    let listLine = lines[i]
                    let listTrimmed = listLine.trimmingCharacters(in: .whitespaces)

                    if listTrimmed.hasPrefix("- ") {
                        // New list item
                        var dict: [String: Any] = [:]
                        let firstEntry = String(listTrimmed.dropFirst(2))
                        if let (k, v) = parseKeyValue(firstEntry) {
                            dict[k] = v
                        }
                        i += 1
                        // Read continuation lines (indented, no dash)
                        while i < lines.count {
                            let contLine = lines[i]
                            let contTrimmed = contLine.trimmingCharacters(in: .whitespaces)
                            if contTrimmed.isEmpty || contTrimmed.hasPrefix("- ") || !contLine.hasPrefix("  ") {
                                break
                            }
                            if let (k, v) = parseKeyValue(contTrimmed) {
                                dict[k] = v
                            }
                            i += 1
                        }
                        snippetsList.append(dict)
                    } else if !listTrimmed.isEmpty && !listLine.hasPrefix(" ") && !listLine.hasPrefix("\t") {
                        break
                    } else {
                        i += 1
                    }
                }
                result["snippets"] = snippetsList
                continue
            }

            result[key] = parseScalarValue(valueStr)
            i += 1
        }

        return result
    }

    private static func parseKeyValue(_ str: String) -> (String, Any)? {
        guard let colonIdx = str.firstIndex(of: ":") else { return nil }
        let key = String(str[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let value = String(str[str.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        return (key, parseScalarValue(value))
    }

    private static func parseScalarValue(_ str: String) -> Any {
        // Quoted string
        if (str.hasPrefix("\"") && str.hasSuffix("\"")) ||
           (str.hasPrefix("'") && str.hasSuffix("'")) {
            return String(str.dropFirst().dropLast())
        }

        // Boolean
        let lower = str.lowercased()
        if lower == "true" { return true }
        if lower == "false" { return false }

        return str
    }

    private static func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        if let b = value as? Bool { return b }
        if let s = value as? String { return s.lowercased() != "false" }
        return defaultValue
    }

    // MARK: - Random sections

    /// Split body into variant sections separated by `===` lines.
    static func splitRandomSections(_ body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        var sections: [[String]] = []
        var current: [String] = []

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped == "===" {
                sections.append(current)
                current = []
            } else if stripped == "\\===" {
                current.append(line.replacingOccurrences(of: "\\===", with: "==="))
            } else {
                current.append(line)
            }
        }
        sections.append(current)

        return sections
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Placeholder expansion

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let datetimeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func expandPlaceholders(_ content: String, clipboard: String? = nil) -> String {
        let lbrace = "\u{0000}LBRACE\u{0000}"
        let rbrace = "\u{0000}RBRACE\u{0000}"

        var result = content
            .replacingOccurrences(of: "{{", with: lbrace)
            .replacingOccurrences(of: "}}", with: rbrace)

        let now = Date()
        result = result
            .replacingOccurrences(of: "{date}", with: dateFmt.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeFmt.string(from: now))
            .replacingOccurrences(of: "{datetime}", with: datetimeFmt.string(from: now))

        if result.contains("{clipboard}") {
            let clipText = clipboard ?? ""
            result = result.replacingOccurrences(of: "{clipboard}", with: clipText)
        }

        result = result
            .replacingOccurrences(of: lbrace, with: "{")
            .replacingOccurrences(of: rbrace, with: "}")

        return result
    }

    // MARK: - File formatting

    static func formatSnippetFile(
        keyword: String,
        content: String,
        autoExpand: Bool = true,
        raw: Bool = false,
        isRandom: Bool = false,
        variants: [String]? = nil
    ) -> String {
        let hasFrontmatter = !keyword.isEmpty || !autoExpand || isRandom || raw

        guard hasFrontmatter else { return content }

        var headerLines: [String] = []
        if !keyword.isEmpty { headerLines.append("keyword: \"\(keyword)\"") }
        if isRandom { headerLines.append("random: true") }
        if !autoExpand { headerLines.append("auto_expand: false") }
        if raw { headerLines.append("raw: true") }

        let body: String
        if isRandom, let variants {
            body = variants.map { v in
                v.components(separatedBy: "\n").map { line in
                    line.trimmingCharacters(in: .whitespaces) == "===" ? "\\===" : line
                }.joined(separator: "\n")
            }.joined(separator: "\n===\n")
        } else {
            body = content
        }

        return "---\n\(headerLines.joined(separator: "\n"))\n---\n\(body)"
    }

    // MARK: - Helpers

    private func persistSnippet(
        safeName: String, keyword: String, content: String,
        category: String, autoExpand: Bool, raw: Bool,
        isRandom: Bool, variants: [String]
    ) -> Bool {
        let filePath = snippetFileURL(safeName: safeName, category: category)
        let catDir = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: catDir, withIntermediateDirectories: true)

        let text = Self.formatSnippetFile(
            keyword: keyword, content: content, autoExpand: autoExpand,
            raw: raw, isRandom: isRandom, variants: isRandom ? variants : nil
        )
        do {
            try text.write(to: filePath, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        let displayContent = isRandom ? variants.joined(separator: "\n\n") : content
        let snippet = Snippet(
            name: safeName, keyword: keyword, content: displayContent,
            category: category, filePath: filePath.path,
            autoExpand: autoExpand, raw: raw,
            isRandom: isRandom, variants: variants
        )
        snippets.append(snippet)
        return true
    }

    private func snippetFileURL(safeName: String, category: String) -> URL {
        let catDir = category.isEmpty ? directory : directory.appendingPathComponent(category)
        return catDir.appendingPathComponent("\(safeName).md")
    }

    static func sanitizeFilename(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "<>:\"/\\|?*")
            .union(CharacterSet(charactersIn: "\u{0000}"..."\u{001F}"))
        var result = name.unicodeScalars
            .map { unsafe.contains($0) ? "_" : String($0) }
            .joined()
        result = result.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_. "))
        return result.isEmpty ? "snippet" : result
    }

    private static func trashFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// MARK: - String helpers

private extension String {
    func trimmingTrailingNewlines() -> String {
        guard let lastNonNewline = lastIndex(where: { $0 != "\n" }) else { return "" }
        return String(self[...lastNonNewline])
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
