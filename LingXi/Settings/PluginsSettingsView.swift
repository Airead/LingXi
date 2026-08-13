//
//  PluginsSettingsView.swift
//  LingXi
//

import SwiftUI

struct PluginsSettingsView: View {
    @Bindable var model: PluginsSettingsModel

    var body: some View {
        Form {
            if let error = model.errorMessage {
                Section {
                    HStack {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss") { model.errorMessage = nil }
                            .buttonStyle(.link)
                    }
                }
            }

            Section {
                ForEach(model.installedRows) { row in
                    PluginRow(row: row, model: model)
                }
                if model.installedRows.isEmpty {
                    Text("No plugins installed.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Installed")
                    if model.hasUpdates {
                        Button("Update All") {
                            Task { await model.updateAll() }
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Section {
                ForEach(model.availableRows) { row in
                    PluginRow(row: row, model: model)
                }
                if model.registryLoadFailed {
                    Text("Could not load the plugin registry.")
                        .foregroundStyle(.secondary)
                } else if model.availableRows.isEmpty {
                    Text("No additional plugins available.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Available")
                    Button("Refresh Registry") {
                        Task { await model.refresh(forceRegistry: true) }
                    }
                    .buttonStyle(.link)
                    .disabled(model.isRefreshing)
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        .confirmationDialog(
            "Uninstall \(model.pendingUninstallID ?? "plugin")?",
            isPresented: Binding(
                get: { model.pendingUninstallID != nil },
                set: { if !$0 { model.pendingUninstallID = nil } }
            )
        ) {
            Button("Uninstall", role: .destructive) {
                if let id = model.pendingUninstallID {
                    Task { await model.uninstall(id: id) }
                }
            }
        } message: {
            Text("This removes the plugin from disk.")
        }
    }
}

// MARK: - Row

private struct PluginRow: View {
    let row: PluginRowModel
    let model: PluginsSettingsModel

    private var isBusy: Bool { model.busyPluginIDs.contains(row.id) }

    var body: some View {
        DisclosureGroup {
            detail
        } label: {
            label
        }
        .padding(.vertical, 2)
    }

    private var label: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .fontWeight(.medium)
                    Text(versionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !row.description.isEmpty {
                    Text(row.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            statusBadge

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                actionButtons
            }
        }
    }

    private var versionText: String {
        if let latest = row.latestVersion {
            return "\(row.version) → \(latest)"
        }
        return row.version
    }

    private var statusBadge: some View {
        let (title, color) = badgeStyle(for: row.status)
        return Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private func badgeStyle(for status: PluginStatus) -> (String, Color) {
        switch status {
        case .installed: ("Installed", .green)
        case .updateAvailable: ("Update Available", .orange)
        case .disabled: ("Disabled", .gray)
        case .manuallyPlaced: ("Manual", .blue)
        case .notInstalled: ("Not Installed", .secondary)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch row.status {
        case .notInstalled:
            linkButton("Install") { await model.install(id: row.id) }
        case .installed:
            linkButton("Disable") { await model.setEnabled(false, id: row.id) }
            uninstallButton
        case .updateAvailable:
            linkButton("Update") { await model.update(id: row.id) }
            linkButton("Disable") { await model.setEnabled(false, id: row.id) }
            uninstallButton
        case .disabled:
            linkButton("Enable") { await model.setEnabled(true, id: row.id) }
            uninstallButton
        case .manuallyPlaced:
            linkButton("Disable") { await model.setEnabled(false, id: row.id) }
        }
    }

    private func linkButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button(title) {
            Task { await action() }
        }
        .buttonStyle(.link)
    }

    private var uninstallButton: some View {
        Button("Uninstall", role: .destructive) {
            model.pendingUninstallID = row.id
        }
        .buttonStyle(.link)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !row.author.isEmpty {
                detailRow("Author", row.author)
            }
            detailRow("Version", row.version)
            if let source = row.sourceURL {
                detailRow("Source", source.absoluteString)
            }
            if !row.description.isEmpty {
                detailRow("Description", row.description)
            }
            detailRow("Permissions", permissionsSummary)
        }
        .padding(.top, 4)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private var permissionsSummary: String {
        guard let permissions = row.permissions else {
            return "Available after install"
        }
        var items: [String] = []
        if permissions.network { items.append("network") }
        if permissions.clipboard { items.append("clipboard") }
        if !permissions.filesystem.isEmpty {
            items.append("filesystem (\(permissions.filesystem.count) paths)")
        }
        if !permissions.shell.isEmpty {
            items.append("shell (\(permissions.shell.count) commands)")
        }
        if permissions.notify { items.append("notify") }
        if permissions.store { items.append("store") }
        if permissions.webview { items.append("webview") }
        if permissions.cache { items.append("cache") }
        if permissions.db { items.append("db") }
        if !permissions.dbExternalPaths.isEmpty {
            items.append("db external (\(permissions.dbExternalPaths.count) paths)")
        }
        return items.isEmpty ? "None" : items.joined(separator: ", ")
    }
}
