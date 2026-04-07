import AppKit

/// Searches macOS System Settings panes and sub-items.
///
/// Supports two registration modes:
/// - **Prefix mode** (`"ss"`): full search, empty query returns all top-level panels.
/// - **Mixed mode** (no prefix, registered as default): returns up to 5 results, empty query returns nothing.
actor SystemSettingsProvider: SearchProvider {

    // MARK: - Data model

    struct SettingsEntry: Sendable {
        let title: String
        let paneId: String
        let anchor: String?
        let subId: String?
        let parentTitle: String
        let keywords: [String]
        let appexName: String

        var url: URL? {
            var str = "\(urlScheme):\(paneId)"
            if let anchor {
                str += "?\(anchor)"
            } else if let subId {
                str += ":\(subId)"
            }
            return URL(string: str)
        }

        var breadcrumb: String {
            parentTitle.isEmpty ? title : "\(parentTitle) \u{203a} \(title)"
        }

        var itemId: String {
            let suffix = anchor ?? subId ?? paneId
            return "system_settings:\(suffix)"
        }

        var searchableFields: [String] {
            var fields = [title, breadcrumb]
            fields.append(contentsOf: keywords)
            return fields
        }
    }

    // MARK: - Properties

    private nonisolated static let urlScheme = "x-apple.systempreferences"
    private nonisolated static let extensionsDir = "/System/Library/ExtensionKit/Extensions"
    private nonisolated static let modifierActions: [ActionModifier: ModifierAction] = [.command: .copyURL]
    private nonisolated static let defaultPanelScore: Double = 30

    private let entries: [SettingsEntry]
    private let maxMixedResults: Int
    private let iconCache = AppIconCache()

    init(maxMixedResults: Int = 5) {
        self.entries = Self.buildEntries()
        self.maxMixedResults = maxMixedResults
        Task { await self.preloadIcons() }
    }

    // MARK: - SearchProvider

    func search(query: String) async -> [SearchResult] {
        searchInternal(query: query, limit: nil, emptyQueryReturnsAll: true)
    }

    /// Mixed-mode search: no results on empty query, limited count.
    func searchMixed(query: String) async -> [SearchResult] {
        searchInternal(query: query, limit: maxMixedResults, emptyQueryReturnsAll: false)
    }

    private func searchInternal(query: String, limit: Int?, emptyQueryReturnsAll: Bool) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces)

        let matched: [(item: SettingsEntry, score: Double)]
        if q.isEmpty {
            guard emptyQueryReturnsAll else { return [] }
            matched = entries
                .filter { $0.parentTitle.isEmpty }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { ($0, Self.defaultPanelScore) }
        } else {
            matched = scoredItems(from: entries, query: q, names: \.searchableFields)
        }

        let capped = limit.map { Array(matched.prefix($0)) } ?? matched
        return capped.map { entry, score in
            let icon = iconForAppex(entry.appexName)
            return SearchResult(
                itemId: entry.itemId,
                icon: icon,
                name: entry.title,
                subtitle: entry.parentTitle.isEmpty ? "System Settings" : entry.breadcrumb,
                resultType: .systemSettings,
                url: entry.url,
                score: score,
                modifierActions: Self.modifierActions
            )
        }
    }

    // MARK: - Icons

    private func iconForAppex(_ appexName: String) -> NSImage? {
        guard !appexName.isEmpty else { return nil }
        let appexPath = "\(Self.extensionsDir)/\(appexName).appex"
        return iconCache.icon(forFile: appexPath)
    }

    private func preloadIcons() async {
        let extDir = Self.extensionsDir
        let paths = Set(entries.compactMap { $0.appexName.isEmpty ? nil : $0.appexName })
            .map { "\(extDir)/\($0).appex" }
        await iconCache.preload(paths: paths)
    }

    // MARK: - Static entry data

    private nonisolated static let privacyPane = "com.apple.settings.PrivacySecurity.extension"
    private nonisolated static let appleIdPane = "com.apple.systempreferences.AppleIDSettings"

    static func buildEntries() -> [SettingsEntry] {
        var entries: [SettingsEntry] = []

        for panel in topLevelPanels {
            entries.append(SettingsEntry(
                title: panel.title, paneId: panel.paneId, anchor: nil, subId: nil,
                parentTitle: "", keywords: panel.keywords, appexName: panel.appexName
            ))
        }

        let privacyAppex = topLevelPanels.first { $0.paneId == privacyPane }?.appexName ?? ""
        for item in privacyAnchors {
            entries.append(SettingsEntry(
                title: item.title, paneId: privacyPane, anchor: item.anchor, subId: nil,
                parentTitle: "Privacy & Security", keywords: item.keywords, appexName: privacyAppex
            ))
        }

        for panel in generalSubpanels {
            entries.append(SettingsEntry(
                title: panel.title, paneId: panel.paneId, anchor: nil, subId: nil,
                parentTitle: "General", keywords: panel.keywords, appexName: panel.appexName
            ))
        }

        let appleIdAppex = topLevelPanels.first { $0.paneId == appleIdPane }?.appexName ?? ""
        entries.append(SettingsEntry(
            title: "iCloud", paneId: appleIdPane, anchor: nil, subId: "icloud",
            parentTitle: "Apple Account", keywords: ["icloud", "cloud", "sync", "icloud drive"],
            appexName: appleIdAppex
        ))

        return entries
    }

    // MARK: - Panel data

    private struct PanelData {
        let title: String
        let paneId: String
        let appexName: String
        let keywords: [String]
    }

    private struct AnchorData {
        let title: String
        let anchor: String
        let keywords: [String]
    }

    private static let topLevelPanels: [PanelData] = [
        .init(title: "Wi-Fi", paneId: "com.apple.wifi-settings-extension", appexName: "Wi-Fi",
              keywords: ["wifi", "wireless", "network", "internet"]),
        .init(title: "Bluetooth", paneId: "com.apple.BluetoothSettings", appexName: "Bluetooth",
              keywords: ["bluetooth", "bt", "wireless"]),
        .init(title: "Network", paneId: "com.apple.Network-Settings.extension", appexName: "Network",
              keywords: ["network", "ethernet", "proxy", "dns"]),
        .init(title: "VPN", paneId: "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", appexName: "VPN",
              keywords: ["vpn", "tunnel"]),
        .init(title: "Notifications", paneId: "com.apple.Notifications-Settings.extension", appexName: "NotificationsSettings",
              keywords: ["notifications", "alerts", "banners"]),
        .init(title: "Sound", paneId: "com.apple.Sound-Settings.extension", appexName: "Sound",
              keywords: ["sound", "audio", "volume", "output", "input"]),
        .init(title: "Focus", paneId: "com.apple.Focus-Settings.extension", appexName: "FocusSettingsExtension",
              keywords: ["focus", "do not disturb", "dnd"]),
        .init(title: "Screen Time", paneId: "com.apple.Screen-Time-Settings.extension", appexName: "ScreenTimePreferencesExtension",
              keywords: ["screen time", "parental", "limits"]),
        .init(title: "General", paneId: "com.apple.systempreferences.GeneralSettings", appexName: "",
              keywords: ["general"]),
        .init(title: "Appearance", paneId: "com.apple.Appearance-Settings.extension", appexName: "Appearance",
              keywords: ["appearance", "dark mode", "light mode", "accent color"]),
        .init(title: "Accessibility", paneId: "com.apple.Accessibility-Settings.extension", appexName: "AccessibilitySettingsExtension",
              keywords: ["accessibility", "a11y", "voiceover", "zoom"]),
        .init(title: "Control Centre", paneId: "com.apple.ControlCenter-Settings.extension", appexName: "ControlCenterSettings",
              keywords: ["control centre", "control center", "menu bar"]),
        .init(title: "Apple Intelligence & Siri", paneId: "com.apple.Siri-Settings.extension", appexName: "AssistantSettingsControlsExtension",
              keywords: ["siri", "apple intelligence", "ai"]),
        .init(title: "Spotlight", paneId: "com.apple.Spotlight-Settings.extension", appexName: "SpotlightPreferenceExtension",
              keywords: ["spotlight", "search"]),
        .init(title: "Privacy & Security", paneId: "com.apple.settings.PrivacySecurity.extension", appexName: "SecurityPrivacyExtension",
              keywords: ["privacy", "security", "permissions"]),
        .init(title: "Desktop & Dock", paneId: "com.apple.Desktop-Settings.extension", appexName: "DesktopSettings",
              keywords: ["desktop", "dock", "mission control", "hot corners", "stage manager"]),
        .init(title: "Displays", paneId: "com.apple.Displays-Settings.extension", appexName: "DisplaysExt",
              keywords: ["displays", "monitor", "resolution", "night shift", "true tone"]),
        .init(title: "Wallpaper", paneId: "com.apple.Wallpaper-Settings.extension", appexName: "Wallpaper",
              keywords: ["wallpaper", "background", "desktop picture"]),
        .init(title: "Screen Saver", paneId: "com.apple.ScreenSaver-Settings.extension", appexName: "",
              keywords: ["screen saver", "screensaver"]),
        .init(title: "Battery", paneId: "com.apple.Battery-Settings.extension", appexName: "PowerPreferences",
              keywords: ["battery", "energy", "power"]),
        .init(title: "Lock Screen", paneId: "com.apple.Lock-Screen-Settings.extension", appexName: "LockScreen",
              keywords: ["lock screen", "login window"]),
        .init(title: "Touch ID & Password", paneId: "com.apple.Touch-ID-Settings.extension", appexName: "Touch ID & Password",
              keywords: ["touch id", "password", "fingerprint"]),
        .init(title: "Users & Groups", paneId: "com.apple.Users-Groups-Settings.extension", appexName: "UsersGroups",
              keywords: ["users", "groups", "accounts", "login"]),
        .init(title: "Autofill & Passwords", paneId: "com.apple.Passwords-Settings.extension", appexName: "",
              keywords: ["passwords", "passkeys", "keychain", "autofill"]),
        .init(title: "Internet Accounts", paneId: "com.apple.Internet-Accounts-Settings.extension", appexName: "InternetAccountsSettingsExtension",
              keywords: ["internet accounts", "email", "mail accounts"]),
        .init(title: "Game Centre", paneId: "com.apple.Game-Center-Settings.extension", appexName: "GameCenterMacOSSettingsExtension",
              keywords: ["game centre", "game center"]),
        .init(title: "Game Controllers", paneId: "com.apple.Game-Controller-Settings.extension", appexName: "GameControllerMacSettings",
              keywords: ["game controllers", "gamepad", "joystick"]),
        .init(title: "Keyboard", paneId: "com.apple.Keyboard-Settings.extension", appexName: "KeyboardSettings",
              keywords: ["keyboard", "shortcuts", "text replacement", "dictation", "input sources"]),
        .init(title: "Mouse", paneId: "com.apple.Mouse-Settings.extension", appexName: "MouseExtension",
              keywords: ["mouse", "scroll", "tracking"]),
        .init(title: "Trackpad", paneId: "com.apple.Trackpad-Settings.extension", appexName: "TrackpadExtension",
              keywords: ["trackpad", "gesture", "tap", "click"]),
        .init(title: "Printers & Scanners", paneId: "com.apple.Print-Scan-Settings.extension", appexName: "PrinterScannerSettings",
              keywords: ["printers", "scanners", "print"]),
        .init(title: "Wallet & Apple Pay", paneId: "com.apple.WalletSettingsExtension", appexName: "WalletSettingsExtension",
              keywords: ["wallet", "apple pay", "payment"]),
        .init(title: "Apple Account", paneId: "com.apple.systempreferences.AppleIDSettings", appexName: "AppleIDSettings",
              keywords: ["apple account", "apple id", "icloud", "account"]),
        .init(title: "Family", paneId: "com.apple.preferences.FamilySharingPrefPane", appexName: "FamilySettings",
              keywords: ["family", "family sharing", "parental"]),
        .init(title: "AppleCare & Warranty", paneId: "com.apple.Coverage-Settings.extension", appexName: "CoverageSettings",
              keywords: ["applecare", "warranty", "coverage"]),
        .init(title: "Device Management", paneId: "com.apple.preferences.configurationprofiles", appexName: "ProfilesSettingsExt",
              keywords: ["device management", "profiles", "mdm"]),
    ]

    private static let privacyAnchors: [AnchorData] = [
        .init(title: "Accessibility", anchor: "Privacy_Accessibility", keywords: ["accessibility", "a11y", "assistive"]),
        .init(title: "Camera", anchor: "Privacy_Camera", keywords: ["camera", "webcam", "video"]),
        .init(title: "Microphone", anchor: "Privacy_Microphone", keywords: ["microphone", "mic", "audio", "recording"]),
        .init(title: "Screen Recording", anchor: "Privacy_ScreenCapture", keywords: ["screen recording", "screen capture"]),
        .init(title: "Location Services", anchor: "Privacy_LocationServices", keywords: ["location", "gps"]),
        .init(title: "Photos", anchor: "Privacy_Photos", keywords: ["photos", "photo library"]),
        .init(title: "Files and Folders", anchor: "Privacy_FilesAndFolders", keywords: ["files", "folders", "file access"]),
        .init(title: "Full Disk Access", anchor: "Privacy_AllFiles", keywords: ["full disk", "disk access"]),
        .init(title: "Automation", anchor: "Privacy_Automation", keywords: ["automation", "applescript", "scripting"]),
        .init(title: "Developer Tools", anchor: "Privacy_DevTools", keywords: ["developer", "dev tools"]),
        .init(title: "Input Monitoring", anchor: "Privacy_ListenEvent", keywords: ["input monitoring", "keyboard"]),
        .init(title: "Calendars", anchor: "Privacy_Calendars", keywords: []),
        .init(title: "Contacts", anchor: "Privacy_Contacts", keywords: []),
        .init(title: "Reminders", anchor: "Privacy_Reminders", keywords: []),
        .init(title: "Bluetooth", anchor: "Privacy_Bluetooth", keywords: []),
        .init(title: "Analytics & Improvements", anchor: "Privacy_Analytics", keywords: ["analytics", "diagnostics", "telemetry"]),
        .init(title: "Apple Advertising", anchor: "Privacy_Advertising", keywords: ["advertising", "ads"]),
        .init(title: "Pasteboard", anchor: "Privacy_Pasteboard", keywords: ["pasteboard", "clipboard"]),
        .init(title: "Media & Apple Music", anchor: "Privacy_Media", keywords: []),
        .init(title: "Desktop Folder", anchor: "Privacy_DesktopFolder", keywords: []),
        .init(title: "Documents Folder", anchor: "Privacy_DocumentsFolder", keywords: []),
        .init(title: "Downloads Folder", anchor: "Privacy_DownloadsFolder", keywords: []),
        .init(title: "FileVault", anchor: "FileVault", keywords: ["filevault", "encryption", "disk encryption"]),
        .init(title: "Lockdown Mode", anchor: "LockdownMode", keywords: []),
    ]

    private static let generalSubpanels: [PanelData] = [
        .init(title: "About", paneId: "com.apple.SystemProfiler.AboutExtension", appexName: "AboutExtension",
              keywords: ["about", "system info", "serial number"]),
        .init(title: "Software Update", paneId: "com.apple.Software-Update-Settings.extension", appexName: "SoftwareUpdateSettingsExtension",
              keywords: ["software update", "update", "upgrade", "macos update"]),
        .init(title: "Storage", paneId: "com.apple.settings.Storage", appexName: "Storage",
              keywords: ["storage", "disk space"]),
        .init(title: "AirDrop & Handoff", paneId: "com.apple.AirDrop-Handoff-Settings.extension", appexName: "AirDropHandoffExtension",
              keywords: ["airdrop", "handoff"]),
        .init(title: "Login Items & Extensions", paneId: "com.apple.LoginItems-Settings.extension", appexName: "LoginItems",
              keywords: ["login items", "startup", "launch at login", "extensions"]),
        .init(title: "Language & Region", paneId: "com.apple.Localization-Settings.extension", appexName: "InternationalSettingsExtension",
              keywords: ["language", "region", "locale"]),
        .init(title: "Date & Time", paneId: "com.apple.Date-Time-Settings.extension", appexName: "DateAndTime Extension",
              keywords: ["date", "time", "timezone"]),
        .init(title: "Sharing", paneId: "com.apple.Sharing-Settings.extension", appexName: "Sharing",
              keywords: ["sharing", "file sharing", "screen sharing"]),
        .init(title: "Time Machine", paneId: "com.apple.Time-Machine-Settings.extension", appexName: "TimeMachineSettings",
              keywords: ["time machine", "backup"]),
        .init(title: "Transfer or Reset", paneId: "com.apple.Transfer-Reset-Settings.extension", appexName: "TransferResetExtension",
              keywords: ["transfer", "reset", "erase"]),
        .init(title: "Startup Disk", paneId: "com.apple.Startup-Disk-Settings.extension", appexName: "StartupDisk",
              keywords: ["startup disk", "boot"]),
    ]
}

// MARK: - Mixed-mode wrapper

/// Thin wrapper that delegates to ``SystemSettingsProvider/searchMixed(query:)``
/// for use as a default (unprefixed) provider.
actor SystemSettingsMixedProvider: SearchProvider {
    private let source: SystemSettingsProvider

    init(source: SystemSettingsProvider) {
        self.source = source
    }

    func search(query: String) async -> [SearchResult] {
        await source.searchMixed(query: query)
    }
}
