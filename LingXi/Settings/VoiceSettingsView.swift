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
    @State private var managingASRProviders = false
    @State private var managingLLMProviders = false

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
                Toggle("Show Recording HUD", isOn: $settings.voiceHUDEnabled)
                Text("A floating indicator at the bottom of the screen with the audio level and live partial text while recording.")
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

            Section("Speech Recognition") {
                selectionRow(
                    title: "Apple Speech",
                    subtitle: "On-device",
                    isSelected: settings.voiceASRSelection == .apple
                ) {
                    settings.voiceASRSelection = .apple
                }
                ForEach(settings.voiceASRProviders) { provider in
                    ForEach(provider.models, id: \.self) { model in
                        selectionRow(
                            title: "\(provider.name) · \(model)",
                            subtitle: provider.baseURL,
                            isSelected: settings.voiceASRSelection == .remote(provider: provider.name, model: model)
                        ) {
                            settings.voiceASRSelection = .remote(provider: provider.name, model: model)
                        }
                    }
                }
                Button("Manage Providers…") { managingASRProviders = true }
                Picker("Language", selection: $settings.voiceLanguage) {
                    ForEach(VoiceLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            Section("Enhancement") {
                Toggle("Polish with LLM", isOn: $settings.voiceEnhanceEnabled)
                Text("After transcription, send the text to an OpenAI-compatible chat endpoint to fix typos and punctuation. On failure or timeout the raw transcription is pasted unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.voiceEnhanceEnabled {
                    if settings.voiceLLMProviders.isEmpty {
                        Text("No LLM provider configured. Add one to enable enhancement.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(settings.voiceLLMProviders) { provider in
                        ForEach(provider.models, id: \.self) { model in
                            selectionRow(
                                title: "\(provider.name) · \(model)",
                                subtitle: provider.baseURL,
                                isSelected: settings.voiceLLMSelection == LLMSelection(provider: provider.name, model: model)
                            ) {
                                settings.voiceLLMSelection = LLMSelection(provider: provider.name, model: model)
                            }
                        }
                    }
                    Button("Manage Providers…") { managingLLMProviders = true }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System Prompt")
                        TextEditor(text: $settings.voiceEnhancePrompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 60, maxHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }

            Section("Preview") {
                Toggle("Preview before pasting", isOn: $settings.voicePreviewEnabled)
                Text("Show the final text in a floating panel before pasting: press Return to paste (after optional edits), Escape to discard. When off, text is pasted immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                permissionRow(.microphone)
                if settings.voiceASRSelection == .apple {
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
        .onChange(of: settings.voiceASRProviders) { _, _ in normalizeASRSelection() }
        .onChange(of: settings.voiceLLMProviders) { _, _ in normalizeLLMSelection() }
        .sheet(isPresented: $managingASRProviders) {
            VoiceProviderManagerView(
                title: "Speech Recognition Providers",
                kind: .asr,
                providers: $settings.voiceASRProviders,
                activeProviderName: activeASRProviderName,
                onRename: { old, new in
                    if case .remote(let provider, let model) = settings.voiceASRSelection, provider == old {
                        settings.voiceASRSelection = .remote(provider: new, model: model)
                    }
                }
            )
        }
        .sheet(isPresented: $managingLLMProviders) {
            VoiceProviderManagerView(
                title: "LLM Providers",
                kind: .llm,
                providers: $settings.voiceLLMProviders,
                activeProviderName: settings.voiceLLMSelection.provider,
                onRename: { old, new in
                    if settings.voiceLLMSelection.provider == old {
                        settings.voiceLLMSelection.provider = new
                    }
                }
            )
        }
    }

    private var activeASRProviderName: String? {
        if case .remote(let provider, _) = settings.voiceASRSelection { return provider }
        return nil
    }

    /// Keeps the persisted selection pointing at something that exists so the
    /// radio list never shows an empty selection after provider edits.
    private func normalizeASRSelection() {
        switch VoiceProviderResolver.resolveASR(
            selection: settings.voiceASRSelection, providers: settings.voiceASRProviders
        ) {
        case .apple:
            settings.voiceASRSelection = .apple
        case .remote(let provider, let model):
            settings.voiceASRSelection = .remote(provider: provider.name, model: model)
        }
    }

    private func normalizeLLMSelection() {
        guard let resolved = VoiceProviderResolver.resolveLLM(
            selection: settings.voiceLLMSelection, providers: settings.voiceLLMProviders
        ) else {
            settings.voiceLLMSelection = LLMSelection(provider: "", model: "")
            return
        }
        settings.voiceLLMSelection = LLMSelection(provider: resolved.provider.name, model: resolved.model)
    }

    private func selectionRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let usesAppleSpeech = settings.voiceASRSelection == .apple
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            if usesAppleSpeech {
                _ = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
            }
            checker.refresh()
        }
    }
}

// MARK: - Provider manager

enum VoiceProviderKind {
    case asr
    case llm
}

struct VoiceProviderManagerView: View {
    let title: String
    let kind: VoiceProviderKind
    @Binding var providers: [VoiceProvider]
    let activeProviderName: String?
    var onRename: (_ old: String, _ new: String) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var editingDraft: ProviderDraft?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            List {
                ForEach(providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(provider.name).fontWeight(.medium)
                                if provider.name == activeProviderName {
                                    Text("active")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(provider.baseURL) · \(provider.models.count) model(s)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editingDraft = ProviderDraft(provider: provider) }
                        Button("Remove", role: .destructive) { remove(provider) }
                            .disabled(provider.name == activeProviderName)
                    }
                    .padding(.vertical, 2)
                }
                if providers.isEmpty {
                    Text("No providers yet. Any OpenAI-compatible endpoint works (e.g. Groq, OpenAI, Ollama).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Add Provider…") { editingDraft = ProviderDraft() }
                Spacer()
            }
            .padding()
        }
        .frame(width: 480, height: 360)
        .sheet(item: $editingDraft) { draft in
            VoiceProviderEditorView(
                kind: kind,
                draft: draft,
                existingNames: providers.map(\.name),
                onSave: { saved in apply(saved) }
            )
        }
    }

    private func remove(_ provider: VoiceProvider) {
        providers.removeAll { $0.name == provider.name }
    }

    private func apply(_ draft: ProviderDraft) {
        let provider = draft.toProvider()
        if let originalName = draft.originalName,
           let index = providers.firstIndex(where: { $0.name == originalName }) {
            providers[index] = provider
            if originalName != provider.name {
                onRename(originalName, provider.name)
            }
        } else {
            providers.append(provider)
        }
    }
}

// MARK: - Provider editor

struct ProviderDraft: Identifiable {
    let id = UUID()
    var originalName: String?
    var name = ""
    var baseURL = ""
    var apiKey = ""
    var modelsText = ""

    init() {}

    init(provider: VoiceProvider) {
        originalName = provider.name
        name = provider.name
        baseURL = provider.baseURL
        apiKey = provider.apiKey
        modelsText = provider.models.joined(separator: "\n")
    }

    var models: [String] {
        modelsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func toProvider() -> VoiceProvider {
        VoiceProvider(
            name: name.trimmingCharacters(in: .whitespaces),
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            apiKey: apiKey.trimmingCharacters(in: .whitespaces),
            models: models
        )
    }
}

struct VoiceProviderEditorView: View {
    let kind: VoiceProviderKind
    @State var draft: ProviderDraft
    let existingNames: [String]
    let onSave: (ProviderDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var verifyState: VerifyState = .idle

    private enum VerifyState: Equatable {
        case idle
        case running
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.originalName == nil ? "Add Provider" : "Edit Provider")
                .font(.headline)

            Form {
                TextField("Name", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL)
                SecureField("API Key (optional for local servers)", text: $draft.apiKey)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models (one per line)")
                    TextEditor(text: $draft.modelsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }
            }

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("Verify") { verify() }
                    .disabled(verifyState == .running || draft.models.isEmpty || draft.baseURL.isEmpty)
                switch verifyState {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView().controlSize(.small)
                case .success:
                    Label("OK", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil)
            }
        }
        .padding()
        .frame(width: 440)
    }

    private var validationError: String? {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Name is required." }
        if name != draft.originalName && existingNames.contains(name) {
            return "A provider named \u{201C}\(name)\u{201D} already exists."
        }
        if draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return "Base URL is required." }
        if draft.models.isEmpty { return "At least one model is required." }
        return nil
    }

    /// Sends a minimal request using the first model in the list.
    private func verify() {
        let provider = draft.toProvider()
        guard let model = provider.models.first else { return }
        verifyState = .running
        let kind = kind
        Task {
            do {
                switch kind {
                case .asr:
                    try await VoiceProviderVerifier.verifyASR(provider: provider, model: model)
                case .llm:
                    try await VoiceProviderVerifier.verifyLLM(provider: provider, model: model)
                }
                verifyState = .success
            } catch TranscriptionError.apiError(let statusCode, _) {
                verifyState = .failure("HTTP \(statusCode)")
            } catch {
                verifyState = .failure(error.localizedDescription)
            }
        }
    }
}
