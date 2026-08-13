//
//  VoiceSettingsView.swift
//  LingXi
//

import AVFoundation
import Speech
import SwiftUI

struct VoiceSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var checker = PermissionChecker()
    @State private var leaderUsesFn = false

    var body: some View {
        Form {
            Section("Voice Input") {
                Toggle("Enable Voice Input", isOn: $settings.voiceInputEnabled)
                Text("Hold the Fn key to record, release to transcribe and paste into the frontmost app. Presses shorter than 0.25s are ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tip: in System Settings → Keyboard, set \u{201C}Press 🌐 key to\u{201D} to \u{201C}Do Nothing\u{201D} so holding Fn doesn't switch input sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if leaderUsesFn && settings.voiceInputEnabled {
                    Label(
                        "Your leader key config uses Fn; that trigger is disabled while voice input is on.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Recognition") {
                Picker("Backend", selection: $settings.voiceBackend) {
                    ForEach(VoiceBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Picker("Language", selection: $settings.voiceLanguage) {
                    ForEach(VoiceLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            if settings.voiceBackend == .whisperAPI {
                Section("Whisper API") {
                    TextField("Base URL", text: $settings.voiceAPIBaseURL)
                    SecureField("API Key", text: $settings.voiceAPIKey)
                    TextField("Model", text: $settings.voiceAPIModel)
                    Text("Any OpenAI-compatible transcription endpoint works (e.g. Groq, OpenAI).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                permissionRow(.microphone)
                if settings.voiceBackend == .apple {
                    permissionRow(.speechRecognition)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checker.refresh()
            leaderUsesFn = LeaderKeyConfigLoader.load().contains { $0.triggerKey == "fn" }
        }
        .onChange(of: settings.voiceInputEnabled) { _, enabled in
            if enabled { requestPermissions() }
        }
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = checker.status(for: kind)
        let statusColor: Color = status.isGranted ? .green : .red
        return HStack {
            Text(kind.name)
            Spacer()
            Text(status.isGranted ? "Granted" : "Not Granted")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
            Button("Open Settings") {
                checker.openSettings(for: kind)
            }
            .buttonStyle(.link)
        }
    }

    /// Trigger the TCC prompts right when the user enables the feature,
    /// instead of surprising them mid-recording.
    private func requestPermissions() {
        let backend = settings.voiceBackend
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            if backend == .apple {
                _ = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
            }
            checker.refresh()
        }
    }
}
