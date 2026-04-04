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
