//
//  ConversationHistory.swift
//  LingXi
//

import Foundation

// MARK: - Record

/// One line of `conversation_history.jsonl`, aligned with WenZi's schema.
nonisolated struct ConversationRecord: Codable, Sendable, Equatable {
    var timestamp: String
    var asrText: String
    var enhancedText: String?
    var finalText: String
    var enhanceMode: String
    var previewEnabled: Bool
    var asrModel: String
    var llmModel: String
    var userCorrected: Bool
    var audioDuration: Double

    enum CodingKeys: String, CodingKey {
        case timestamp
        case asrText = "asr_text"
        case enhancedText = "enhanced_text"
        case finalText = "final_text"
        case enhanceMode = "enhance_mode"
        case previewEnabled = "preview_enabled"
        case asrModel = "asr_model"
        case llmModel = "llm_model"
        case userCorrected = "user_corrected"
        case audioDuration = "audio_duration"
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func makeTimestamp(_ date: Date = Date()) -> String {
        iso8601.string(from: date)
    }
}

// MARK: - History actor

/// Append-only JSONL log of finished voice sessions, plus the prompt
/// injection blocks built from confirmed previews. All file IO stays off the
/// main actor; failures are logged and never block enhancement or pasting.
actor ConversationHistory {
    struct Limits: Sendable {
        /// Injection list size after a rebuild.
        var maxEntries = 10
        /// Rebuild the injection list once it grows to this many entries.
        var refreshThreshold = 50
        /// Rebuild the injection list once it grows to this many characters.
        var maxChars = 6000
        /// Skip the rotation check while the file is smaller than this.
        var rotationCheckBytes = 4 * 1024 * 1024
        /// Records kept in the main file after rotation.
        var maxRecords = 20_000
    }

    private let directory: URL
    private let limits: Limits

    /// Formatted injection lines per mode. Appended to on every confirmed
    /// preview so the prompt prefix stays stable for LLM caching; rebuilt
    /// from file (shrunk to `maxEntries`) when a threshold is hit.
    private var injectionLists: [String: [String]] = [:]

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/LingXi", isDirectory: true)
    }

    init(directory: URL? = nil, limits: Limits = Limits()) {
        self.directory = directory ?? Self.defaultDirectory
        self.limits = limits
    }

    private var fileURL: URL {
        directory.appendingPathComponent("conversation_history.jsonl")
    }

    private var archivesDirectory: URL {
        directory.appendingPathComponent("conversation_history_archives", isDirectory: true)
    }

    // MARK: - Recording

    func record(_ entry: ConversationRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(entry)
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            DebugLog.log("[History] failed to record entry: \(error)")
            return
        }

        // Keep the in-memory injection list append-stable. On first use the
        // rebuild reads the file, which already contains the entry just
        // written — appending it again would duplicate it.
        if entry.previewEnabled {
            if var list = injectionLists[entry.enhanceMode] {
                list.append(Self.formatInjectionLine(entry))
                injectionLists[entry.enhanceMode] = list
            } else {
                injectionLists[entry.enhanceMode] = rebuildInjectionList(mode: entry.enhanceMode)
            }
        }

        rotateIfNeeded()
    }

    // MARK: - Prompt injection

    static let injectionHeader = """
    以下是用户此前确认过的转写示例（格式：识别 → 确认；只有一段表示无需修改），\
    请与这些示例保持一致的用词、术语和纠错习惯：
    """

    /// The history block to append to the mode's system prompt, or nil when
    /// there is nothing to inject (or reading the file failed).
    func injectionBlock(mode: String) -> String? {
        var list = injectionLists[mode] ?? rebuildInjectionList(mode: mode)
        if list.count >= limits.refreshThreshold
            || list.reduce(0, { $0 + $1.count }) >= limits.maxChars {
            list = rebuildInjectionList(mode: mode)
        }
        injectionLists[mode] = list
        guard !list.isEmpty else { return nil }
        return Self.injectionHeader + "\n" + list.joined(separator: "\n")
    }

    private func rebuildInjectionList(mode: String) -> [String] {
        readRecords()
            .filter { $0.previewEnabled && $0.enhanceMode == mode }
            .suffix(limits.maxEntries)
            .map(Self.formatInjectionLine)
    }

    /// `识别 → 确认`; a single segment when the user confirmed the ASR text
    /// unchanged.
    nonisolated static func formatInjectionLine(_ entry: ConversationRecord) -> String {
        let asr = entry.asrText.replacingOccurrences(of: "\n", with: " ")
        let final = entry.finalText.replacingOccurrences(of: "\n", with: " ")
        return asr == final ? final : "\(asr) → \(final)"
    }

    // MARK: - Reading

    /// All parseable records in the main file; corrupt lines are skipped.
    func readRecords() -> [ConversationRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content.split(whereSeparator: \.isNewline).compactMap { line in
            guard let record = try? decoder.decode(ConversationRecord.self, from: Data(line.utf8)) else {
                DebugLog.log("[History] skipping corrupt line")
                return nil
            }
            return record
        }
    }

    // MARK: - Rotation

    /// Archives all but the newest `maxRecords` lines into per-month files,
    /// then atomically replaces the main file. Only runs once the file has
    /// grown past `rotationCheckBytes`.
    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int, size >= limits.rotationCheckBytes else {
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else { return }
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > limits.maxRecords else { return }

        let overflow = lines.prefix(lines.count - limits.maxRecords)
        let kept = lines.suffix(limits.maxRecords)

        do {
            try FileManager.default.createDirectory(at: archivesDirectory, withIntermediateDirectories: true)
            for (month, monthLines) in Self.groupByMonth(Array(overflow)) {
                let archiveURL = archivesDirectory.appendingPathComponent("\(month).jsonl")
                var block = Data((monthLines.joined(separator: "\n") + "\n").utf8)
                if let handle = try? FileHandle(forWritingTo: archiveURL) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: block)
                } else {
                    try block.write(to: archiveURL)
                }
                block.removeAll()
            }

            // Atomic replacement of the main file with the kept tail.
            let tempURL = directory.appendingPathComponent("conversation_history.jsonl.tmp")
            try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: tempURL)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            DebugLog.log("[History] rotated \(overflow.count) records into archives")
        } catch {
            DebugLog.log("[History] rotation failed: \(error)")
        }
    }

    /// Groups raw JSONL lines by the `YYYY-MM` of their timestamp; lines
    /// without a parseable timestamp land in "unknown". Ordering within a
    /// month is preserved.
    nonisolated static func groupByMonth(_ lines: [String]) -> [(month: String, lines: [String])] {
        var groups: [String: [String]] = [:]
        var order: [String] = []
        let decoder = JSONDecoder()
        for line in lines {
            struct TimestampOnly: Decodable { let timestamp: String }
            var month = "unknown"
            if let parsed = try? decoder.decode(TimestampOnly.self, from: Data(line.utf8)) {
                let prefix = String(parsed.timestamp.prefix(7))
                // Expect "YYYY-MM".
                if prefix.count == 7, prefix.dropFirst(4).first == "-",
                   prefix.prefix(4).allSatisfy(\.isNumber), prefix.suffix(2).allSatisfy(\.isNumber) {
                    month = prefix
                }
            }
            if groups[month] == nil { order.append(month) }
            groups[month, default: []].append(line)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}
