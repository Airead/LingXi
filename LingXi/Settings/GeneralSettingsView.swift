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

            Section("Screenshot") {
                LabeledContent("Region Capture") {
                    HotKeyRecorderView(
                        keyCode: $settings.screenshotRegionHotKeyKeyCode,
                        modifiers: $settings.screenshotRegionHotKeyModifiers,
                        allowEmpty: true
                    )
                    .frame(width: 160, height: 28)
                }
                LabeledContent("Full Screen Capture") {
                    HotKeyRecorderView(
                        keyCode: $settings.screenshotFullScreenHotKeyKeyCode,
                        modifiers: $settings.screenshotFullScreenHotKeyModifiers,
                        allowEmpty: true
                    )
                    .frame(width: 160, height: 28)
                }
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
