//
//  PermissionChecker.swift
//  LingXi
//

import AppKit
import ScreenCaptureKit

enum PermissionStatus {
    case granted
    case notGranted

    var isGranted: Bool { self == .granted }
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case fullDiskAccess

    var id: String { rawValue }

    var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    var description: String {
        switch self {
        case .accessibility: "Required for global hotkeys, leader key, and snippet expansion"
        case .screenRecording: "Required for screen capture features"
        case .fullDiskAccess: "Required for reading Safari bookmarks"
        }
    }

    nonisolated func checkStatus() -> PermissionStatus {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .fullDiskAccess:
            let path = BookmarkStore.defaultSafariPath
            return FileManager.default.isReadableFile(atPath: path) ? .granted : .notGranted
        }
    }

    var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        let fragment: String = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .fullDiskAccess: "Privacy_AllFiles"
        }
        return URL(string: "\(base)?\(fragment)")!
    }
}

@Observable
final class PermissionChecker {
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    init() {
        refresh()
    }

    func refresh() {
        for kind in PermissionKind.allCases {
            let newStatus = kind.checkStatus()
            if statuses[kind] != newStatus {
                statuses[kind] = newStatus
            }
        }
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notGranted
    }

    func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
