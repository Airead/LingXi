//
//  AppSettings.swift
//  LingXi
//

import Carbon
import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
final class AppSettings {
    // MARK: - Singleton

    static let shared = AppSettings()

    // MARK: - General

    var hotKeyKeyCode: UInt32 {
        didSet { guard hotKeyKeyCode != oldValue else { return }; save(.hotKeyKeyCode, value: hotKeyKeyCode) }
    }
    var hotKeyModifiers: UInt32 {
        didSet { guard hotKeyModifiers != oldValue else { return }; save(.hotKeyModifiers, value: hotKeyModifiers) }
    }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            save(.launchAtLogin, value: launchAtLogin)
            updateLaunchAtLogin()
        }
    }
    var appearanceMode: AppearanceMode {
        didSet { guard appearanceMode != oldValue else { return }; save(.appearanceMode, value: appearanceMode.rawValue) }
    }

    // MARK: - Search

    var maxSearchResults: Int {
        didSet {
            let clamped = max(1, min(maxSearchResults, 100))
            if clamped != maxSearchResults { maxSearchResults = clamped; return }
            guard maxSearchResults != oldValue else { return }
            save(.maxSearchResults, value: maxSearchResults)
        }
    }
    var applicationSearchEnabled: Bool {
        didSet { guard applicationSearchEnabled != oldValue else { return }; save(.applicationSearchEnabled, value: applicationSearchEnabled) }
    }
    var fileSearchEnabled: Bool {
        didSet { guard fileSearchEnabled != oldValue else { return }; save(.fileSearchEnabled, value: fileSearchEnabled) }
    }
    var folderSearchEnabled: Bool {
        didSet { guard folderSearchEnabled != oldValue else { return }; save(.folderSearchEnabled, value: folderSearchEnabled) }
    }
    var bookmarkSearchEnabled: Bool {
        didSet { guard bookmarkSearchEnabled != oldValue else { return }; save(.bookmarkSearchEnabled, value: bookmarkSearchEnabled) }
    }
    var fileSearchPrefix: String {
        didSet {
            if fileSearchPrefix.trimmingCharacters(in: .whitespaces).isEmpty { fileSearchPrefix = oldValue; return }
            guard fileSearchPrefix != oldValue else { return }; save(.fileSearchPrefix, value: fileSearchPrefix)
        }
    }
    var folderSearchPrefix: String {
        didSet {
            if folderSearchPrefix.trimmingCharacters(in: .whitespaces).isEmpty { folderSearchPrefix = oldValue; return }
            guard folderSearchPrefix != oldValue else { return }; save(.folderSearchPrefix, value: folderSearchPrefix)
        }
    }
    var bookmarkSearchPrefix: String {
        didSet {
            if bookmarkSearchPrefix.trimmingCharacters(in: .whitespaces).isEmpty { bookmarkSearchPrefix = oldValue; return }
            guard bookmarkSearchPrefix != oldValue else { return }; save(.bookmarkSearchPrefix, value: bookmarkSearchPrefix)
        }
    }
    var clipboardHistoryEnabled: Bool {
        didSet { guard clipboardHistoryEnabled != oldValue else { return }; save(.clipboardHistoryEnabled, value: clipboardHistoryEnabled) }
    }
    var clipboardSearchPrefix: String {
        didSet {
            if clipboardSearchPrefix.trimmingCharacters(in: .whitespaces).isEmpty { clipboardSearchPrefix = oldValue; return }
            guard clipboardSearchPrefix != oldValue else { return }; save(.clipboardSearchPrefix, value: clipboardSearchPrefix)
        }
    }
    var clipboardHistoryCapacity: Int {
        didSet {
            let clamped = max(10, min(clipboardHistoryCapacity, 1000))
            if clamped != clipboardHistoryCapacity { clipboardHistoryCapacity = clamped; return }
            guard clipboardHistoryCapacity != oldValue else { return }
            save(.clipboardHistoryCapacity, value: clipboardHistoryCapacity)
        }
    }

    // MARK: - Source hotkeys (0/0 = not set)

    var fileSearchHotKeyKeyCode: UInt32 {
        didSet { guard fileSearchHotKeyKeyCode != oldValue else { return }; save(.fileSearchHotKeyKeyCode, value: fileSearchHotKeyKeyCode) }
    }
    var fileSearchHotKeyModifiers: UInt32 {
        didSet { guard fileSearchHotKeyModifiers != oldValue else { return }; save(.fileSearchHotKeyModifiers, value: fileSearchHotKeyModifiers) }
    }
    var folderSearchHotKeyKeyCode: UInt32 {
        didSet { guard folderSearchHotKeyKeyCode != oldValue else { return }; save(.folderSearchHotKeyKeyCode, value: folderSearchHotKeyKeyCode) }
    }
    var folderSearchHotKeyModifiers: UInt32 {
        didSet { guard folderSearchHotKeyModifiers != oldValue else { return }; save(.folderSearchHotKeyModifiers, value: folderSearchHotKeyModifiers) }
    }
    var bookmarkSearchHotKeyKeyCode: UInt32 {
        didSet { guard bookmarkSearchHotKeyKeyCode != oldValue else { return }; save(.bookmarkSearchHotKeyKeyCode, value: bookmarkSearchHotKeyKeyCode) }
    }
    var bookmarkSearchHotKeyModifiers: UInt32 {
        didSet { guard bookmarkSearchHotKeyModifiers != oldValue else { return }; save(.bookmarkSearchHotKeyModifiers, value: bookmarkSearchHotKeyModifiers) }
    }
    var clipboardSearchHotKeyKeyCode: UInt32 {
        didSet { guard clipboardSearchHotKeyKeyCode != oldValue else { return }; save(.clipboardSearchHotKeyKeyCode, value: clipboardSearchHotKeyKeyCode) }
    }
    var clipboardSearchHotKeyModifiers: UInt32 {
        didSet { guard clipboardSearchHotKeyModifiers != oldValue else { return }; save(.clipboardSearchHotKeyModifiers, value: clipboardSearchHotKeyModifiers) }
    }

    // MARK: - Appearance mode

    enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: "Follow System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    // MARK: - Keys

    private enum Key: String {
        case hotKeyKeyCode = "io.github.airead.lingxi.hotKeyKeyCode"
        case hotKeyModifiers = "io.github.airead.lingxi.hotKeyModifiers"
        case launchAtLogin = "io.github.airead.lingxi.launchAtLogin"
        case appearanceMode = "io.github.airead.lingxi.appearanceMode"
        case maxSearchResults = "io.github.airead.lingxi.maxSearchResults"
        case applicationSearchEnabled = "io.github.airead.lingxi.applicationSearchEnabled"
        case fileSearchEnabled = "io.github.airead.lingxi.fileSearchEnabled"
        case folderSearchEnabled = "io.github.airead.lingxi.folderSearchEnabled"
        case bookmarkSearchEnabled = "io.github.airead.lingxi.bookmarkSearchEnabled"
        case fileSearchPrefix = "io.github.airead.lingxi.fileSearchPrefix"
        case folderSearchPrefix = "io.github.airead.lingxi.folderSearchPrefix"
        case bookmarkSearchPrefix = "io.github.airead.lingxi.bookmarkSearchPrefix"
        case clipboardHistoryEnabled = "io.github.airead.lingxi.clipboardHistoryEnabled"
        case clipboardSearchPrefix = "io.github.airead.lingxi.clipboardSearchPrefix"
        case clipboardHistoryCapacity = "io.github.airead.lingxi.clipboardHistoryCapacity"
        case fileSearchHotKeyKeyCode = "io.github.airead.lingxi.fileSearchHotKeyKeyCode"
        case fileSearchHotKeyModifiers = "io.github.airead.lingxi.fileSearchHotKeyModifiers"
        case folderSearchHotKeyKeyCode = "io.github.airead.lingxi.folderSearchHotKeyKeyCode"
        case folderSearchHotKeyModifiers = "io.github.airead.lingxi.folderSearchHotKeyModifiers"
        case bookmarkSearchHotKeyKeyCode = "io.github.airead.lingxi.bookmarkSearchHotKeyKeyCode"
        case bookmarkSearchHotKeyModifiers = "io.github.airead.lingxi.bookmarkSearchHotKeyModifiers"
        case clipboardSearchHotKeyKeyCode = "io.github.airead.lingxi.clipboardSearchHotKeyKeyCode"
        case clipboardSearchHotKeyModifiers = "io.github.airead.lingxi.clipboardSearchHotKeyModifiers"
    }

    // MARK: - Defaults

    nonisolated static let defaultHotKeyKeyCode = UInt32(kVK_Space)
    nonisolated static let defaultHotKeyModifiers = UInt32(optionKey)

    // MARK: - Init

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        hotKeyKeyCode = Self.load(defaults, .hotKeyKeyCode) ?? Self.defaultHotKeyKeyCode
        hotKeyModifiers = Self.load(defaults, .hotKeyModifiers) ?? Self.defaultHotKeyModifiers
        launchAtLogin = Self.load(defaults, .launchAtLogin) ?? false
        maxSearchResults = Self.load(defaults, .maxSearchResults) ?? 20
        applicationSearchEnabled = Self.load(defaults, .applicationSearchEnabled) ?? true
        fileSearchEnabled = Self.load(defaults, .fileSearchEnabled) ?? true
        folderSearchEnabled = Self.load(defaults, .folderSearchEnabled) ?? true
        bookmarkSearchEnabled = Self.load(defaults, .bookmarkSearchEnabled) ?? true
        fileSearchPrefix = Self.load(defaults, .fileSearchPrefix) ?? "f"
        folderSearchPrefix = Self.load(defaults, .folderSearchPrefix) ?? "fd"
        bookmarkSearchPrefix = Self.load(defaults, .bookmarkSearchPrefix) ?? "bm"
        clipboardHistoryEnabled = Self.load(defaults, .clipboardHistoryEnabled) ?? true
        clipboardSearchPrefix = Self.load(defaults, .clipboardSearchPrefix) ?? "cb"
        clipboardHistoryCapacity = Self.load(defaults, .clipboardHistoryCapacity) ?? 200

        fileSearchHotKeyKeyCode = Self.load(defaults, .fileSearchHotKeyKeyCode) ?? 0
        fileSearchHotKeyModifiers = Self.load(defaults, .fileSearchHotKeyModifiers) ?? 0
        folderSearchHotKeyKeyCode = Self.load(defaults, .folderSearchHotKeyKeyCode) ?? 0
        folderSearchHotKeyModifiers = Self.load(defaults, .folderSearchHotKeyModifiers) ?? 0
        bookmarkSearchHotKeyKeyCode = Self.load(defaults, .bookmarkSearchHotKeyKeyCode) ?? 0
        bookmarkSearchHotKeyModifiers = Self.load(defaults, .bookmarkSearchHotKeyModifiers) ?? 0
        clipboardSearchHotKeyKeyCode = Self.load(defaults, .clipboardSearchHotKeyKeyCode) ?? 0
        clipboardSearchHotKeyModifiers = Self.load(defaults, .clipboardSearchHotKeyModifiers) ?? 0

        let modeRaw: String? = Self.load(defaults, .appearanceMode)
        appearanceMode = modeRaw.flatMap { AppearanceMode(rawValue: $0) } ?? .system
    }

    // MARK: - Persistence helpers

    private func save<T>(_ key: Key, value: T) {
        defaults.set(value, forKey: key.rawValue)
    }

    private static func load<T>(_ defaults: UserDefaults, _ key: Key) -> T? {
        defaults.object(forKey: key.rawValue) as? T
    }

    // MARK: - Launch at login

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
    }

    // MARK: - Hotkey display

    var hotKeyDisplayString: String {
        Self.displayString(keyCode: hotKeyKeyCode, modifiers: hotKeyModifiers)
    }

    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        parts.append(keyCodeName(keyCode))
        return parts.joined()
    }

    private static let keyCodeNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "\u{21A9}",
        UInt32(kVK_Tab): "\u{21E5}",
        UInt32(kVK_Delete): "\u{232B}",
        UInt32(kVK_Escape): "\u{238B}",
        UInt32(kVK_UpArrow): "\u{2191}",
        UInt32(kVK_DownArrow): "\u{2193}",
        UInt32(kVK_LeftArrow): "\u{2190}",
        UInt32(kVK_RightArrow): "\u{2192}",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func isHotKeySet(keyCode: UInt32, modifiers: UInt32) -> Bool {
        keyCode != 0 || modifiers != 0
    }

    private static var translatedKeyCodeCache: [UInt32: String] = [:]

    static func keyCodeName(_ keyCode: UInt32) -> String {
        if let name = keyCodeNames[keyCode] { return name }
        if let cached = translatedKeyCodeCache[keyCode] { return cached }

        let result = translateKeyCode(keyCode)
        translatedKeyCodeCache[keyCode] = result
        return result
    }

    private static func translateKeyCode(_ keyCode: UInt32) -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        var layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        if layoutData == nil {
            let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            layoutData = TISGetInputSourceProperty(asciiSource, kTISPropertyUnicodeKeyLayoutData)
        }
        guard let layoutData else {
            return "?"
        }
        let data = unsafeBitCast(layoutData, to: CFData.self) as Data
        return data.withUnsafeBytes { rawBuffer -> String in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return "?"
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            let status = UCKeyTranslate(
                ptr, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
