//
//  SettingsView.swift
//  LingXi
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .search: "Search"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .search: "magnifyingglass"
        }
    }
}

struct SettingsView: View {
    var settings: AppSettings
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
            }
        }
    }
}
