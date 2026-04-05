import AppKit
import Combine
import SwiftUI

/// Floating panel for creating a new snippet with real-time validation.
@MainActor
final class SnippetEditorPanel {
    private var panel: NSPanel?
    private let store: SnippetStore
    private var lastCategory: String = ""

    init(store: SnippetStore) {
        self.store = store
    }

    func show(onSaved: (() -> Void)? = nil) {
        close()

        let viewModel = SnippetEditorViewModel(
            store: store,
            initialCategory: lastCategory,
            onSave: { [weak self] category in
                self?.lastCategory = category
                onSaved?()
                self?.close()
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )

        if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
            viewModel.content = clip
        }

        let hostingView = NSHostingView(rootView: SnippetEditorView(viewModel: viewModel))
        let width: CGFloat = 420
        let height: CGFloat = 400

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "New Snippet"
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.contentView = hostingView

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.midX - width / 2
            let y = sf.midY - height / 2
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            newPanel.center()
        }

        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = newPanel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - ViewModel

@MainActor
final class SnippetEditorViewModel: ObservableObject {
    @Published var name: String = ""
    @Published var keyword: String = ""
    @Published var content: String = ""
    @Published private(set) var errorMessage: String?

    private let store: SnippetStore
    private let onSave: (String) -> Void
    private let onCancel: () -> Void

    init(store: SnippetStore, initialCategory: String = "", onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel

        let prefix = initialCategory.isEmpty ? "" : "\(initialCategory)/"
        name = "\(prefix)untitled"
    }

    private func parseName() -> (category: String, name: String) {
        let raw = name.trimmingCharacters(in: .whitespaces)
        guard let slashIndex = raw.lastIndex(of: "/") else {
            return ("", raw)
        }
        let category = String(raw[raw.startIndex..<slashIndex]).trimmingCharacters(in: .whitespaces)
        let snippetName = String(raw[raw.index(after: slashIndex)...]).trimmingCharacters(in: .whitespaces)
        return (category, snippetName)
    }

    func save() {
        errorMessage = nil
        let (category, snippetName) = parseName()

        if snippetName.isEmpty {
            errorMessage = "Name cannot be empty."
            return
        }

        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespaces)

        Task {
            let result = await store.validateAndAdd(
                name: snippetName, category: category,
                keyword: trimmedKeyword, content: content
            )
            switch result {
            case .success:
                onSave(category)
            case .failure(let error):
                switch error {
                case .fileExists(let name):
                    errorMessage = "A snippet named \"\(name)\" already exists."
                case .keywordInUse(let kw):
                    errorMessage = "Keyword \"\(kw)\" is already in use."
                case .contentDuplicates(let label):
                    errorMessage = "Content duplicates \"\(label)\"."
                case .writeFailed:
                    errorMessage = "Failed to write snippet file."
                }
            }
        }
    }

    func cancel() {
        onCancel()
    }
}

// MARK: - View

private struct SnippetEditorView: View {
    @ObservedObject var viewModel: SnippetEditorViewModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, keyword, content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("Name", placeholder: "category/name", text: $viewModel.name, field: .name)
                .onSubmit { viewModel.save() }

            labeledField("Keyword", placeholder: "Optional trigger keyword", text: $viewModel.keyword, field: .keyword)
                .onSubmit { viewModel.save() }

            VStack(alignment: .leading, spacing: 4) {
                Text("Content")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.content)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .focused($focusedField, equals: .content)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    viewModel.save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 360)
        .onAppear {
            focusedField = .name
        }
    }

    private func labeledField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
        }
    }
}
