//
//  PanelManager.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

private enum PanelLayout {
    static let defaultWidth: CGFloat = 680
    static let previewListWidth: CGFloat = 480
    static let previewWidth: CGFloat = 540
    static let searchBarHeight: CGFloat = 48
    static let rowHeight: CGFloat = 44
    static let maxVisibleRows = 8
    static let maxShortcutKeys = 9
}

@MainActor
final class PanelManager {
    private var panel: FloatingPanel?
    private let router: SearchRouter
    private let viewModel: SearchViewModel
    private let clipboardStore: ClipboardStore
    private let inputSourceManager = InputSourceManager()
    private var sizeObserver: AnyCancellable?
    private var previousApp: NSRunningApplication?

    init(settings: AppSettings) async {
        let db = await DatabaseManager(databasePath: DatabaseManager.defaultDatabasePath())
        let clipboardStore = ClipboardStore(database: db, capacity: settings.clipboardHistoryCapacity)
        self.clipboardStore = clipboardStore
        let copyHandler: @MainActor @Sendable (Int) -> Void = { itemId in
            Task { await clipboardStore.writeToClipboard(itemId: itemId) }
        }
        let router = SearchRouter(defaultProvider: ApplicationSearchProvider(), maxResults: settings.maxSearchResults)
        router.register(prefix: settings.folderSearchPrefix, id: "folder", provider: FileSearchProvider(contentType: .foldersOnly))
        router.register(prefix: settings.fileSearchPrefix, id: "file", provider: FileSearchProvider(contentType: .excludeFolders))
        router.register(prefix: settings.bookmarkSearchPrefix, id: "bookmark", provider: BookmarkSearchProvider())
        router.register(prefix: settings.clipboardSearchPrefix, id: "clipboard", provider: ClipboardHistoryProvider(store: clipboardStore, copyHandler: copyHandler))
        self.router = router
        self.viewModel = await SearchViewModel(router: router, database: db)

        viewModel.onDeleteItem = { [weak self] itemId in
            guard let self, let id = self.clipboardId(from: itemId) else { return }
            Task { await self.clipboardStore.delete(itemId: id) }
        }

        viewModel.onClipboardPaste = { [weak self] itemId in
            guard let self, let id = self.clipboardId(from: itemId) else { return }
            let target = self.previousApp
            Task {
                await self.clipboardStore.writeToClipboard(itemId: id)
                target?.activate()
                try? await Task.sleep(nanoseconds: 150_000_000)
                Self.simulatePaste()
            }
        }

        applySettings(settings)
        self.panel = createPanel()
    }

    func applySettings(_ settings: AppSettings) {
        router.setMaxResults(settings.maxSearchResults)
        router.setEnabled(settings.applicationSearchEnabled, forId: "default")
        router.setEnabled(settings.fileSearchEnabled, forId: "file")
        router.setEnabled(settings.folderSearchEnabled, forId: "folder")
        router.setEnabled(settings.bookmarkSearchEnabled, forId: "bookmark")
        router.setEnabled(settings.clipboardHistoryEnabled, forId: "clipboard")
        router.updatePrefix(settings.fileSearchPrefix, forId: "file")
        router.updatePrefix(settings.folderSearchPrefix, forId: "folder")
        router.updatePrefix(settings.bookmarkSearchPrefix, forId: "bookmark")
        router.updatePrefix(settings.clipboardSearchPrefix, forId: "clipboard")

        let enabled = settings.clipboardHistoryEnabled
        let capacity = settings.clipboardHistoryCapacity
        Task {
            if enabled {
                await clipboardStore.startMonitoring()
            } else {
                await clipboardStore.stopMonitoring()
            }
            await clipboardStore.setCapacity(capacity)
        }
    }

    func saveInputSource() {
        inputSourceManager.save()
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        showWithPrefix(nil)
    }

    func showWithPrefix(_ prefix: String?) {
        let prefixQuery = prefix.map { $0 + " " }

        if let panel, panel.isVisible {
            if let prefixQuery {
                inputSourceManager.switchToASCII()
                viewModel.query = prefixQuery
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication

        let activePanel = panel ?? createPanel()
        self.panel = activePanel

        inputSourceManager.switchToASCII()
        if let prefixQuery {
            viewModel.query = prefixQuery
        } else {
            viewModel.clear()
        }
        positionPanel(activePanel)
        NSApp.activate(ignoringOtherApps: true)
        activePanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        inputSourceManager.restore()
        previousApp = nil
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private func createPanel() -> FloatingPanel {
        let newPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.defaultWidth, height: PanelLayout.searchBarHeight))
        newPanel.contentView = NSHostingView(rootView: PanelContentView(viewModel: viewModel, onDismiss: { [weak self] in
            self?.hide()
        }))
        newPanel.onDismiss = { [weak self] in
            self?.hide()
        }
        newPanel.onCommandComma = {
            AppDelegate.showSettings()
        }
        newPanel.onArrowUp = { [weak viewModel] in
            viewModel?.moveUp()
        }
        newPanel.onArrowDown = { [weak viewModel] in
            viewModel?.moveDown()
        }
        newPanel.onReturn = { [weak self, weak viewModel] modifiers in
            if viewModel?.confirm(modifiers: modifiers) == true {
                self?.hide()
            }
        }
        newPanel.onDelete = { [weak viewModel] in
            viewModel?.deleteSelected()
        }
        newPanel.onModifiersChanged = { [weak viewModel] modifiers in
            guard viewModel?.activeModifiers != modifiers else { return }
            viewModel?.activeModifiers = modifiers
        }
        newPanel.onNumberKey = { [weak self, weak viewModel] index in
            guard let viewModel, viewModel.results.indices.contains(index) else { return }
            viewModel.selectedIndex = index
            if viewModel.confirm() {
                self?.hide()
            }
        }

        // Keep .receive(on:): @Published fires on willSet (before the value is set).
        // Without the dispatch, panel.setFrame(display: true) triggers a SwiftUI layout
        // pass that reads the stale value of viewModel.results.
        sizeObserver = viewModel.$results
            .combineLatest(viewModel.$hasPreview)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak newPanel] (results: [SearchResult], hasPreview: Bool) in
                guard let self, let panel = newPanel else { return }
                self.updatePanelSize(panel, results: results, hasPreview: hasPreview)
            }

        return newPanel
    }

    private func updatePanelSize(_ panel: FloatingPanel, results: [SearchResult], hasPreview: Bool) {
        let visibleRows = min(results.count, PanelLayout.maxVisibleRows)
        let listHeight = CGFloat(visibleRows) * PanelLayout.rowHeight
        let newHeight = PanelLayout.searchBarHeight + listHeight

        let newWidth = hasPreview
            ? PanelLayout.previewListWidth + PanelLayout.previewWidth
            : PanelLayout.defaultWidth

        let oldFrame = panel.frame
        guard newHeight != oldFrame.height || newWidth != oldFrame.width else { return }

        let screenFrame = NSScreen.main?.visibleFrame ?? oldFrame
        let x = screenFrame.midX - newWidth / 2
        let newFrame = NSRect(
            x: x,
            y: oldFrame.origin.y + oldFrame.height - newHeight,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }

    private func clipboardId(from itemId: String) -> Int? {
        ClipboardHistoryProvider.extractId(from: itemId)
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func positionPanel(_ panel: FloatingPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let width = PanelLayout.defaultWidth
        let height = PanelLayout.searchBarHeight
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY + screenFrame.height / 4 - height / 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false, animate: false)
    }
}

private struct PanelContentView: View {
    @ObservedObject var viewModel: SearchViewModel
    var onDismiss: () -> Void
    @FocusState private var isSearchFieldFocused: Bool

    private var selectedPreview: PreviewData? {
        let index = viewModel.selectedIndex
        guard viewModel.results.indices.contains(index) else { return nil }
        return viewModel.results[index].previewData
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                TextField("Search...", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($isSearchFieldFocused)
            }
            .padding(.horizontal, 16)
            .frame(height: PanelLayout.searchBarHeight)

            if !viewModel.results.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    resultsList

                    if let preview = selectedPreview {
                        Divider()
                        PreviewPane(data: preview)
                            .frame(width: PanelLayout.previewWidth)
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onExitCommand {
            onDismiss()
        }
        .onAppear {
            isSearchFieldFocused = true
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        SearchResultRow(
                            result: result,
                            isSelected: index == viewModel.selectedIndex,
                            activeModifiers: viewModel.activeModifiers,
                            shortcutNumber: index < PanelLayout.maxShortcutKeys ? index + 1 : nil
                        )
                        .id(result.id)
                    }
                }
            }
            .onChange(of: viewModel.selectedIndex) { _, newIndex in
                guard viewModel.results.indices.contains(newIndex) else { return }
                withAnimation {
                    proxy.scrollTo(viewModel.results[newIndex].id, anchor: nil)
                }
            }
        }
    }
}

private struct PreviewPane: View {
    let data: PreviewData

    var body: some View {
        switch data {
        case .text(let content):
            ScrollView {
                Text(content)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        case .image(let path, let description):
            VStack(spacing: 12) {
                CachedImageView(url: path) {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
        }
    }
}

private struct CachedImageView<Placeholder: View>: View {
    let url: URL
    let maxPixelSize: Int?
    @ViewBuilder let placeholder: Placeholder
    @State private var nsImage: NSImage?

    init(url: URL, maxPixelSize: Int? = nil, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder()
    }

    var body: some View {
        if let nsImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .task(id: url, loadImage)
        } else {
            placeholder
                .task(id: url, loadImage)
        }
    }

    @Sendable private func loadImage() async {
        if let maxPixelSize {
            nsImage = await ThumbnailCache.shared.loadThumbnail(for: url, maxPixelSize: maxPixelSize)
        } else {
            nsImage = await ThumbnailCache.shared.loadImage(for: url)
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    var isSelected: Bool = false
    var activeModifiers: Set<ActionModifier> = []
    var shortcutNumber: Int?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = result.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let thumbURL = result.thumbnailURL {
                    CachedImageView(url: thumbURL, maxPixelSize: 56) {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
            }
            .frame(width: 28, height: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 15))
                Text(isSelected ? result.displaySubtitle(for: activeModifiers) : result.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: PanelLayout.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}
