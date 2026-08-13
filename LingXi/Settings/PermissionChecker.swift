//
//  PermissionChecker.swift
//  LingXi
//

import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech

enum PermissionStatus {
    case granted
    case notGranted

    var isGranted: Bool { self == .granted }
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case fullDiskAccess
    case microphone
    case speechRecognition

    var id: String { rawValue }

    var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .fullDiskAccess: "Full Disk Access"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        }
    }

    var description: String {
        switch self {
        case .accessibility: "Required for global hotkeys, leader key, and snippet expansion"
        case .screenRecording: "Required for screen capture features"
        case .fullDiskAccess: "Required for reading Safari bookmarks"
        case .microphone: "Required for voice input recording"
        case .speechRecognition: "Required for voice input transcription with Apple Speech"
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
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .notGranted
        case .speechRecognition:
            return SFSpeechRecognizer.authorizationStatus() == .authorized ? .granted : .notGranted
        }
    }

    var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        let fragment: String = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
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
