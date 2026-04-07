//
//  SearchSettingsView.swift
//  LingXi
//

import SwiftUI

struct SearchSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Results") {
                LabeledContent("Maximum Results") {
                    TextField("", value: $settings.maxSearchResults, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.maxSearchResults, in: 1...100)
                        .labelsHidden()
                }
            }

            Section("Data Sources") {
                Toggle("Application Search", isOn: $settings.applicationSearchEnabled)
                dataSourceRow(
                    "File Search",
                    prefix: $settings.fileSearchPrefix,
                    enabled: $settings.fileSearchEnabled,
                    hotKeyKeyCode: $settings.fileSearchHotKeyKeyCode,
                    hotKeyModifiers: $settings.fileSearchHotKeyModifiers
                )
                dataSourceRow(
                    "Folder Search",
                    prefix: $settings.folderSearchPrefix,
                    enabled: $settings.folderSearchEnabled,
                    hotKeyKeyCode: $settings.folderSearchHotKeyKeyCode,
                    hotKeyModifiers: $settings.folderSearchHotKeyModifiers
                )
                dataSourceRow(
                    "Bookmark Search",
                    prefix: $settings.bookmarkSearchPrefix,
                    enabled: $settings.bookmarkSearchEnabled,
                    hotKeyKeyCode: $settings.bookmarkSearchHotKeyKeyCode,
                    hotKeyModifiers: $settings.bookmarkSearchHotKeyModifiers
                )
                dataSourceRow(
                    "Clipboard History",
                    prefix: $settings.clipboardSearchPrefix,
                    enabled: $settings.clipboardHistoryEnabled,
                    hotKeyKeyCode: $settings.clipboardSearchHotKeyKeyCode,
                    hotKeyModifiers: $settings.clipboardSearchHotKeyModifiers
                )
                dataSourceRow(
                    "Snippet Search",
                    prefix: $settings.snippetSearchPrefix,
                    enabled: $settings.snippetSearchEnabled,
                    hotKeyKeyCode: $settings.snippetSearchHotKeyKeyCode,
                    hotKeyModifiers: $settings.snippetSearchHotKeyModifiers
                )
                simpleDataSourceRow(
                    "System Settings Search",
                    prefix: $settings.systemSettingsSearchPrefix,
                    enabled: $settings.systemSettingsSearchEnabled
                )
                Toggle("Snippet Auto-expand", isOn: $settings.snippetAutoExpandEnabled)
                LabeledContent("Clipboard Capacity") {
                    TextField("", value: $settings.clipboardHistoryCapacity, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.clipboardHistoryCapacity, in: 10...1000, step: 10)
                        .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func simpleDataSourceRow(
        _ title: String,
        prefix: Binding<String>,
        enabled: Binding<Bool>
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("", text: prefix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                Toggle("", isOn: enabled)
                    .labelsHidden()
            }
        } label: {
            Text(title)
        }
    }

    private func dataSourceRow(
        _ title: String,
        prefix: Binding<String>,
        enabled: Binding<Bool>,
        hotKeyKeyCode: Binding<UInt32>,
        hotKeyModifiers: Binding<UInt32>
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                HotKeyRecorderView(
                    keyCode: hotKeyKeyCode,
                    modifiers: hotKeyModifiers,
                    allowEmpty: true
                )
                .frame(width: 150, height: 28)
                TextField("", text: prefix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                Toggle("", isOn: enabled)
                    .labelsHidden()
            }
        } label: {
            Text(title)
        }
    }
}
