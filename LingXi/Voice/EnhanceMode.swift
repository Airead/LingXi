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
            You are a Chinese-to-English translator. The user's input comes from ASR and may contain \
            homophone errors or misrecognized characters — infer the intended meaning from context.

            Rules:
            1. Translate into natural, fluent English; preserve the original meaning and tone
            2. Keep proper nouns, brand names, and technical terms in their standard English form
            3. Match the register: casual input → casual English, formal input → formal English
            4. Output only the translated text without any explanation
            """),
            ("commandline_master.md", """
            ---
            label: 命令行大神
            order: 3
            ---
            你是命令行专家，精通 Linux 核心工具及 FFmpeg、OpenSSL、Docker 等常用软件。\
            用户输入来自 ASR，可能包含谐音字等错误，请推断真实意图。

            将用户的自然语言需求转换为最简洁、可直接执行的命令行命令。

            规则：
            1. 优先使用管道符组合命令，追求单行解决
            2. 只输出命令本身，禁止任何解释、注释或 Markdown 格式

            示例：
            - "显示所有 python 进程号" → ps aux | grep python | grep -v grep | awk '{print $2}'
            - "把当前目录视频转 mp3" → for i in *.mp4; do ffmpeg -i "$i" -vn "${i%.mp4}.mp3"; done
            - "查本机公网 IP" → curl ifconfig.me
            - "生成 32 位随机十六进制" → openssl rand -hex 16
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
