//
//  EnhanceMode.swift
//  LingXi
//

import Foundation

// MARK: - Mode model

/// A user-editable enhancement prompt, stored as a Markdown file with YAML
/// front matter in the modes directory. The file name (without `.md`) is the
/// mode ID; `off` is reserved and means "no enhancement".
nonisolated struct EnhanceMode: Sendable, Equatable, Identifiable {
    var id: String
    var label: String
    var order: Int
    var prompt: String

    static let offModeID = "off"
}

// MARK: - Front matter parser (pure, unit-testable)

nonisolated enum EnhanceModeParser {
    /// Supports only single-line `key: value` front matter between `---`
    /// fences. Content without a valid front matter block is treated as a
    /// bare prompt. Unknown keys (including `steps`) are ignored.
    static func parse(id: String, content: String) -> EnhanceMode {
        var label = id
        var order = Int.max
        var prompt = content

        let lines = content.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let closing = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            for line in lines[1..<closing] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "label":
                    if !value.isEmpty { label = value }
                case "order":
                    if let parsed = Int(value) { order = parsed }
                case "steps":
                    DebugLog.log("[EnhanceMode] 'steps' is not supported, ignored (mode: \(id))")
                default:
                    break
                }
            }
            prompt = lines[(closing + 1)...].joined(separator: "\n")
        }

        return EnhanceMode(
            id: id,
            label: label,
            order: order,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Store

/// Loads enhancement modes from the modes directory and seeds the built-in
/// ones on first launch. Directory is injectable for tests.
@MainActor
final class EnhanceModeStore {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/LingXi/enhance_modes", isDirectory: true)
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Creates the built-in mode files if missing; never overwrites existing
    /// files. When a legacy custom prompt is passed (Phase 2 migration), it
    /// becomes `custom.md`.
    func seedBuiltInModes(legacyCustomPrompt: String? = nil) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DebugLog.log("[EnhanceMode] failed to create modes directory: \(error)")
            return
        }

        var seeds: [(file: String, content: String)] = [
            ("proofread.md", """
            ---
            label: 纠错润色
            order: 1
            ---
            \(LLMEnhancerConfiguration.defaultSystemPrompt)
            """),
            ("translate_en.md", """
            ---
            label: 翻译为英文
            order: 2
            ---
            你是翻译助手。将输入的语音转写文本翻译为自然流畅的英文，修正明显的同音字和错别字后再翻译。\
            只输出译文，不要任何解释或额外内容。
            """),
        ]
        if let legacyCustomPrompt, !legacyCustomPrompt.isEmpty {
            seeds.append(("custom.md", """
            ---
            label: 自定义
            order: 100
            ---
            \(legacyCustomPrompt)
            """))
        }

        for seed in seeds {
            let url = directory.appendingPathComponent(seed.file)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try seed.content.write(to: url, atomically: true, encoding: .utf8)
                DebugLog.log("[EnhanceMode] seeded \(seed.file)")
            } catch {
                DebugLog.log("[EnhanceMode] failed to seed \(seed.file): \(error)")
            }
        }
    }

    /// All modes sorted by order then label. The reserved `off` ID is
    /// excluded even if a file with that name exists.
    func loadModes() -> [EnhanceMode] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []

        var modes: [EnhanceMode] = []
        for url in files where url.pathExtension == "md" {
            let id = url.deletingPathExtension().lastPathComponent
            if id == EnhanceMode.offModeID {
                DebugLog.log("[EnhanceMode] '\(EnhanceMode.offModeID).md' ignored: reserved ID")
                continue
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                DebugLog.log("[EnhanceMode] failed to read \(url.lastPathComponent)")
                continue
            }
            modes.append(EnhanceModeParser.parse(id: id, content: content))
        }
        return modes.sorted {
            ($0.order, $0.label) < ($1.order, $1.label)
        }
    }

    /// The system prompt for a mode ID; nil means "do not enhance" (mode is
    /// `off`, or no mode file exists at all). A deleted mode falls back to
    /// the first available one.
    func resolvePrompt(modeID: String) -> String? {
        guard modeID != EnhanceMode.offModeID else { return nil }
        let modes = loadModes()
        if let mode = modes.first(where: { $0.id == modeID }) {
            return mode.prompt
        }
        guard let fallback = modes.first else {
            DebugLog.log("[EnhanceMode] no mode files found, enhancement disabled")
            return nil
        }
        DebugLog.log("[EnhanceMode] mode '\(modeID)' missing, falling back to '\(fallback.id)'")
        return fallback.prompt
    }
}
