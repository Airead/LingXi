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
                dataSourceRow("File Search", prefix: $settings.fileSearchPrefix, enabled: $settings.fileSearchEnabled)
                dataSourceRow("Folder Search", prefix: $settings.folderSearchPrefix, enabled: $settings.folderSearchEnabled)
                dataSourceRow("Bookmark Search", prefix: $settings.bookmarkSearchPrefix, enabled: $settings.bookmarkSearchEnabled)
                dataSourceRow("Clipboard History", prefix: $settings.clipboardSearchPrefix, enabled: $settings.clipboardHistoryEnabled)
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

    private func dataSourceRow(_ title: String, prefix: Binding<String>, enabled: Binding<Bool>) -> some View {
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
}
