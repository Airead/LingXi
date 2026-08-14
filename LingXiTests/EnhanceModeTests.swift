import Foundation
import Testing
@testable import LingXi

// MARK: - Parser

struct EnhanceModeParserTests {

    @Test func parsesFrontMatterAndPrompt() {
        let mode = EnhanceModeParser.parse(id: "proofread", content: """
        ---
        label: 纠错润色
        order: 1
        ---
        Fix typos.
        Keep the meaning.
        """)
        #expect(mode.id == "proofread")
        #expect(mode.label == "纠错润色")
        #expect(mode.order == 1)
        #expect(mode.prompt == "Fix typos.\nKeep the meaning.")
    }

    @Test func missingLabelFallsBackToFileName() {
        let mode = EnhanceModeParser.parse(id: "summarize", content: """
        ---
        order: 3
        ---
        Summarize the text.
        """)
        #expect(mode.label == "summarize")
        #expect(mode.order == 3)
    }

    @Test func noFrontMatterTreatsWholeContentAsPrompt() {
        let mode = EnhanceModeParser.parse(id: "bare", content: "Just a prompt.")
        #expect(mode.label == "bare")
        #expect(mode.order == Int.max)
        #expect(mode.prompt == "Just a prompt.")
    }

    @Test func unclosedFrontMatterTreatsWholeContentAsPrompt() {
        let content = "---\nlabel: broken\nno closing fence"
        let mode = EnhanceModeParser.parse(id: "broken", content: content)
        #expect(mode.label == "broken")
        #expect(mode.prompt == content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func stepsFieldIsIgnored() {
        let mode = EnhanceModeParser.parse(id: "chained", content: """
        ---
        label: Chained
        steps: [a, b]
        ---
        Prompt body.
        """)
        #expect(mode.label == "Chained")
        #expect(mode.prompt == "Prompt body.")
    }

    @Test func badOrderValueIsIgnored() {
        let mode = EnhanceModeParser.parse(id: "x", content: """
        ---
        order: soon
        ---
        p
        """)
        #expect(mode.order == Int.max)
    }
}

// MARK: - Store

@MainActor
struct EnhanceModeStoreTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-modes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func seedCreatesBuiltInModes() {
        let dir = makeTempDirectory()
        let store = EnhanceModeStore(directory: dir)
        store.seedBuiltInModes()

        let modes = store.loadModes()
        #expect(modes.map(\.id) == ["proofread", "translate_en", "commandline_master"])
        #expect(modes[0].label == "纠错润色")
        #expect(modes[0].prompt == LLMEnhancerConfiguration.defaultSystemPrompt)
        #expect(modes[2].label == "命令行大神")
    }

    @Test func seedDoesNotOverwriteExistingFiles() throws {
        let dir = makeTempDirectory()
        let store = EnhanceModeStore(directory: dir)
        try "my own prompt".write(
            to: dir.appendingPathComponent("proofread.md"), atomically: true, encoding: .utf8
        )

        store.seedBuiltInModes()
        let proofread = store.loadModes().first { $0.id == "proofread" }
        #expect(proofread?.prompt == "my own prompt")
    }

    @Test func seedWritesLegacyCustomPrompt() {
        let dir = makeTempDirectory()
        let store = EnhanceModeStore(directory: dir)
        store.seedBuiltInModes(legacyCustomPrompt: "my legacy prompt")

        let custom = store.loadModes().first { $0.id == "custom" }
        #expect(custom?.label == "自定义")
        #expect(custom?.prompt == "my legacy prompt")
    }

    @Test func loadIgnoresNonMarkdownAndReservedOff() throws {
        let dir = makeTempDirectory()
        try "not a mode".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "reserved".write(to: dir.appendingPathComponent("off.md"), atomically: true, encoding: .utf8)
        try "p".write(to: dir.appendingPathComponent("real.md"), atomically: true, encoding: .utf8)

        let modes = EnhanceModeStore(directory: dir).loadModes()
        #expect(modes.map(\.id) == ["real"])
    }

    @Test func loadSortsByOrderThenLabel() throws {
        let dir = makeTempDirectory()
        try "---\norder: 2\n---\np".write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "---\norder: 1\n---\np".write(to: dir.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        try "p".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let modes = EnhanceModeStore(directory: dir).loadModes()
        #expect(modes.map(\.id) == ["c", "b", "a"])
    }

    @Test func resolvePromptOffReturnsNil() {
        let store = EnhanceModeStore(directory: makeTempDirectory())
        store.seedBuiltInModes()
        #expect(store.resolvePrompt(modeID: EnhanceMode.offModeID) == nil)
    }

    @Test func resolvePromptFindsMode() {
        let store = EnhanceModeStore(directory: makeTempDirectory())
        store.seedBuiltInModes()
        #expect(store.resolvePrompt(modeID: "proofread") == LLMEnhancerConfiguration.defaultSystemPrompt)
    }

    @Test func resolvePromptMissingModeFallsBackToFirstAvailable() {
        let store = EnhanceModeStore(directory: makeTempDirectory())
        store.seedBuiltInModes()
        #expect(store.resolvePrompt(modeID: "deleted") == LLMEnhancerConfiguration.defaultSystemPrompt)
    }

    @Test func resolvePromptEmptyDirectoryReturnsNil() {
        let store = EnhanceModeStore(directory: makeTempDirectory())
        #expect(store.resolvePrompt(modeID: "proofread") == nil)
    }
}

// MARK: - Settings migration

@MainActor
struct EnhanceModeMigrationTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "io.github.airead.lingxi.test.\(UUID().uuidString)")!
    }

    @Test func enabledMigratesToProofread() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "io.github.airead.lingxi.voiceEnhanceEnabled")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceEnhanceMode == "proofread")
    }

    @Test func disabledMigratesToOff() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "io.github.airead.lingxi.voiceEnhanceEnabled")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceEnhanceMode == EnhanceMode.offModeID)
    }

    @Test func migrationDoesNotRepeatOnceModeKeyExists() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "io.github.airead.lingxi.voiceEnhanceEnabled")
        let settings1 = AppSettings(defaults: defaults)
        settings1.voiceEnhanceMode = "translate_en"

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.voiceEnhanceMode == "translate_en")
    }

    @Test func consumeLegacyPromptReturnsCustomPromptOnce() {
        let defaults = makeDefaults()
        defaults.set("my custom prompt", forKey: "io.github.airead.lingxi.voiceEnhancePrompt")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.consumeLegacyEnhancePrompt() == "my custom prompt")
        // Key is removed, so the prompt is not returned again.
        #expect(settings.consumeLegacyEnhancePrompt() == nil)
    }

    @Test func consumeLegacyPromptIgnoresDefaultPrompt() {
        let defaults = makeDefaults()
        defaults.set(
            LLMEnhancerConfiguration.defaultSystemPrompt,
            forKey: "io.github.airead.lingxi.voiceEnhancePrompt"
        )
        let settings = AppSettings(defaults: defaults)
        #expect(settings.consumeLegacyEnhancePrompt() == nil)
    }

    @Test func consumeLegacyPromptNilWhenAbsent() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.consumeLegacyEnhancePrompt() == nil)
    }
}
