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
                Toggle("File Search (f )", isOn: $settings.fileSearchEnabled)
                Toggle("Folder Search (fd )", isOn: $settings.folderSearchEnabled)
                Toggle("Bookmark Search (bm )", isOn: $settings.bookmarkSearchEnabled)
            }
        }
        .formStyle(.grouped)
    }
}
