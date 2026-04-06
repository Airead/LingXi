//
//  PermissionsSettingsView.swift
//  LingXi
//

import SwiftUI

struct PermissionsSettingsView: View {
    @State private var checker = PermissionChecker()

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(
                        kind: kind,
                        status: checker.status(for: kind),
                        onOpenSettings: { checker.openSettings(for: kind) }
                    )
                }
            } header: {
                HStack {
                    Text("Permissions")
                    Button("Refresh") {
                        checker.refresh()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checker.refresh()
        }
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let onOpenSettings: () -> Void

    var body: some View {
        let statusColor: Color = status.isGranted ? .green : .red

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name)
                    .fontWeight(.medium)
                Text(kind.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(status.isGranted ? "Granted" : "Not Granted")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    statusColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 4)
                )

            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.link)
        }
        .padding(.vertical, 2)
    }
}
