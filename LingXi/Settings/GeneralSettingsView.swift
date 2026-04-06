//
//  GeneralSettingsView.swift
//  LingXi
//

import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Global Shortcut") {
                    HotKeyRecorderView(
                        keyCode: $settings.hotKeyKeyCode,
                        modifiers: $settings.hotKeyModifiers
                    )
                    .frame(width: 160, height: 28)
                }
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            }

            Section("Leader Key") {
                Toggle("Enable Leader Key", isOn: $settings.leaderKeyEnabled)
                Text("Configure mappings in ~/.config/LingXi/leader.jsonc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppSettings.AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
