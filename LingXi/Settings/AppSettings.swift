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
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
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
