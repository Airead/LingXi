//
//  SettingsView.swift
//  LingXi
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case search
    case voice
    case plugins
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .search: "Search"
        case .voice: "Voice"
        case .plugins: "Plugins"
        case .permissions: "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .search: "magnifyingglass"
        case .voice: "mic"
        case .plugins: "puzzlepiece.extension"
        case .permissions: "shield.lefthalf.filled"
        }
    }
}

struct SettingsView: View {
    var settings: AppSettings
    var pluginsModel: PluginsSettingsModel?
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            switch selectedTab {
            case .general:
                GeneralSettingsView(settings: settings)
            case .search:
                SearchSettingsView(settings: settings)
            case .voice:
                VoiceSettingsView(settings: settings)
            case .plugins:
                if let pluginsModel {
                    PluginsSettingsView(model: pluginsModel)
                } else {
                    ContentUnavailableView(
                        "Plugins Unavailable",
                        systemImage: "puzzlepiece.extension",
                        description: Text("The plugin system is not loaded.")
                    )
                }
            case .permissions:
                PermissionsSettingsView()
            }
        }
    }
}
