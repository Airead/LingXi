//
//  PanelManager.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import AppKit
import Combine
import SwiftUI

private enum PanelLayout {
    static let width: CGFloat = 680
    static let searchBarHeight: CGFloat = 48
    static let rowHeight: CGFloat = 44
    static let maxVisibleRows = 8
}

@MainActor
final class PanelManager {
    private var panel: FloatingPanel?
    private let router: SearchRouter
    private let viewModel: SearchViewModel
    private let clipboardStore: ClipboardStore
    private let inputSourceManager = InputSourceManager()
    private var heightObserver: AnyCancellable?

    init(settings: AppSettings) async {
        let db = await DatabaseManager(databasePath: DatabaseManager.defaultDatabasePath())
        let clipboardStore = ClipboardStore(database: db, capacity: settings.clipboardHistoryCapacity)
        self.clipboardStore = clipboardStore
        let router = SearchRouter(defaultProvider: ApplicationSearchProvider(), maxResults: settings.maxSearchResults)
        router.register(prefix: settings.folderSearchPrefix, id: "folder", provider: FileSearchProvider(contentType: .foldersOnly))
        router.register(prefix: settings.fileSearchPrefix, id: "file", provider: FileSearchProvider(contentType: .excludeFolders))
        router.register(prefix: settings.bookmarkSearchPrefix, id: "bookmark", provider: BookmarkSearchProvider())
        router.register(prefix: settings.clipboardSearchPrefix, id: "clipboard", provider: ClipboardHistoryProvider(store: clipboardStore))
        self.router = router
        self.viewModel = await SearchViewModel(router: router, database: db)

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
        if let panel, panel.isVisible {
            return
        }

        let activePanel = panel ?? createPanel()
        self.panel = activePanel

        inputSourceManager.switchToASCII()
        viewModel.clear()
        positionPanel(activePanel)
        NSApp.activate(ignoringOtherApps: true)
        activePanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        inputSourceManager.restore()
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private func createPanel() -> FloatingPanel {
        let newPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.searchBarHeight))
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
        newPanel.onModifiersChanged = { [weak viewModel] modifiers in
            guard viewModel?.activeModifiers != modifiers else { return }
            viewModel?.activeModifiers = modifiers
        }

        heightObserver = viewModel.$results
            .sink { [weak self, weak newPanel] (results: [SearchResult]) in
                guard let self, let panel = newPanel else { return }
                self.updatePanelHeight(panel, resultCount: results.count)
            }

        return newPanel
    }

    private func updatePanelHeight(_ panel: FloatingPanel, resultCount: Int) {
        let visibleRows = min(resultCount, PanelLayout.maxVisibleRows)
        let listHeight = CGFloat(visibleRows) * PanelLayout.rowHeight
        let newHeight = PanelLayout.searchBarHeight + listHeight

        let oldFrame = panel.frame
        guard newHeight != oldFrame.height else { return }

        let newFrame = NSRect(
            x: oldFrame.origin.x,
            y: oldFrame.origin.y + oldFrame.height - newHeight,
            width: oldFrame.width,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }

    private func positionPanel(_ panel: FloatingPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.midY + screenFrame.height / 4 - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct PanelContentView: View {
    @ObservedObject var viewModel: SearchViewModel
    var onDismiss: () -> Void
    @FocusState private var isSearchFieldFocused: Bool

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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                                SearchResultRow(
                                    result: result,
                                    isSelected: index == viewModel.selectedIndex,
                                    activeModifiers: viewModel.activeModifiers
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onExitCommand {
            onDismiss()
        }
        .onAppear {
            isSearchFieldFocused = true
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    var isSelected: Bool = false
    var activeModifiers: Set<ActionModifier> = []

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = result.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
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
        }
        .padding(.horizontal, 16)
        .frame(height: PanelLayout.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}
