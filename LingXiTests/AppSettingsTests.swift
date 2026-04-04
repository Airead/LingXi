import Carbon
import Testing
@testable import LingXi

@MainActor
struct AppSettingsTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "io.github.airead.lingxi.test.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: makeDefaults())
    }

    @Test func defaultValues() {
        let settings = makeSettings()
        #expect(settings.hotKeyKeyCode == UInt32(kVK_Space))
        #expect(settings.hotKeyModifiers == UInt32(optionKey))
        #expect(settings.launchAtLogin == false)
        #expect(settings.maxSearchResults == 20)
        #expect(settings.applicationSearchEnabled == true)
        #expect(settings.fileSearchEnabled == true)
        #expect(settings.folderSearchEnabled == true)
        #expect(settings.bookmarkSearchEnabled == true)
        #expect(settings.appearanceMode == .system)
    }

    @Test func persistsMaxSearchResults() {
        let defaults = makeDefaults()
        let settings1 = AppSettings(defaults: defaults)
        settings1.maxSearchResults = 42

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.maxSearchResults == 42)
    }

    @Test func persistsAppearanceMode() {
        let defaults = makeDefaults()
        let settings1 = AppSettings(defaults: defaults)
        settings1.appearanceMode = .dark

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.appearanceMode == .dark)
    }

    @Test func persistsHotKey() {
        let defaults = makeDefaults()
        let settings1 = AppSettings(defaults: defaults)
        settings1.hotKeyKeyCode = UInt32(kVK_Return)
        settings1.hotKeyModifiers = UInt32(cmdKey)

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.hotKeyKeyCode == UInt32(kVK_Return))
        #expect(settings2.hotKeyModifiers == UInt32(cmdKey))
    }

    @Test func persistsDataSourceToggles() {
        let defaults = makeDefaults()
        let settings1 = AppSettings(defaults: defaults)
        settings1.applicationSearchEnabled = false
        settings1.bookmarkSearchEnabled = false

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.applicationSearchEnabled == false)
        #expect(settings2.fileSearchEnabled == true)
        #expect(settings2.folderSearchEnabled == true)
        #expect(settings2.bookmarkSearchEnabled == false)
    }

    @Test func defaultPrefixValues() {
        let settings = makeSettings()
        #expect(settings.fileSearchPrefix == "f")
        #expect(settings.folderSearchPrefix == "fd")
        #expect(settings.bookmarkSearchPrefix == "bm")
    }

    @Test func emptyPrefixRevertsToOldValue() {
        let settings = makeSettings()
        settings.fileSearchPrefix = "fi"
        settings.fileSearchPrefix = ""
        #expect(settings.fileSearchPrefix == "fi")
        settings.fileSearchPrefix = "   "
        #expect(settings.fileSearchPrefix == "fi")
    }

    @Test func persistsDataSourcePrefixes() {
        let defaults = makeDefaults()
        let settings1 = AppSettings(defaults: defaults)
        settings1.fileSearchPrefix = "fi"
        settings1.folderSearchPrefix = "dir"
        settings1.bookmarkSearchPrefix = "b"

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.fileSearchPrefix == "fi")
        #expect(settings2.folderSearchPrefix == "dir")
        #expect(settings2.bookmarkSearchPrefix == "b")
    }

    @Test func hotKeyDisplayString() {
        let display = AppSettings.displayString(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        )
        #expect(display == "\u{2325}Space")
    }

    @Test func hotKeyDisplayStringMultipleModifiers() {
        let display = AppSettings.displayString(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey) | UInt32(shiftKey)
        )
        #expect(display == "\u{21E7}\u{2318}Space")
    }
}
