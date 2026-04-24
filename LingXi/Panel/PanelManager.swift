//
//  PanelManager.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import AppKit
import Combine
import SwiftUI
import WebKit

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
    private let pluginService: PluginService
    private let leaderKeyManager: LeaderKeyManager
    private let inputSourceManager = InputSourceManager()
    private var sizeObserver: AnyCancellable?
    var previousApp: NSRunningApplication?
    private let snippetModule: SnippetModule
    private let modules: [SearchProviderModule]

    init(
        settings: AppSettings,
        router: SearchRouter,
        viewModel: SearchViewModel,
        pluginService: PluginService,
        snippetModule: SnippetModule,
        leaderKeyManager: LeaderKeyManager,
        modules: [SearchProviderModule]
    ) {
        self.router = router
        self.viewModel = viewModel
        self.pluginService = pluginService
        self.snippetModule = snippetModule
        self.leaderKeyManager = leaderKeyManager
        self.modules = modules

        applySettings(settings)
        self.panel = createPanel()

        for module in modules {
            module.start()
        }

        if settings.leaderKeyEnabled {
            leaderKeyManager.start()
        }
    }

    func applySettings(_ settings: AppSettings) {
        router.setMaxResults(settings.maxSearchResults)
        for module in modules {
            module.applySettings(settings, router: router)
        }
    }

    func saveInputSource() {
        inputSourceManager.save()
    }

    func toggle() {
        if isVisible {
            hide(returnFocus: true)
        } else {
            show()
        }
    }

    func show() {
        showWithPrefix(nil)
    }

    func showWithPrefix(_ prefix: String?) {
        snippetModule.suppress()
        leaderKeyManager.suppress()
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

        Task {
            await pluginService.dispatchEvent(
                name: PluginEvent.searchActivate.rawValue,
                data: ["prefix": prefix ?? ""]
            )
        }

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

    func hide(returnFocus: Bool = false) {
        guard isVisible else { return }
        panel?.orderOut(nil)
        inputSourceManager.restore()
        // Don't clear previousApp here - let pasteText use it first
        snippetModule.resume()
        leaderKeyManager.resume()
        Task {
            await pluginService.dispatchEvent(
                name: PluginEvent.searchDeactivate.rawValue,
                data: [:]
            )
        }
        if returnFocus {
            previousApp?.activate()
        }
    }

    /// Clear previousApp after paste operations are complete
    func clearPreviousApp() {
        previousApp = nil
    }

    func setAutoExpandEnabled(_ enabled: Bool) {
        snippetModule.setAutoExpandEnabled(enabled)
    }

    func setLeaderKeyEnabled(_ enabled: Bool) {
        if enabled {
            leaderKeyManager.start()
        } else {
            leaderKeyManager.stop()
        }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private func createPanel() -> FloatingPanel {
        let newPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.defaultWidth, height: PanelLayout.searchBarHeight))
        newPanel.contentView = NSHostingView(rootView: PanelContentView(viewModel: viewModel, onDismiss: { [weak self] in
            self?.hide(returnFocus: true)
        }))
        newPanel.onDismiss = { [weak self] in
            self?.hide(returnFocus: true)
        }
        newPanel.onCommandComma = {
            AppDelegate.showSettings()
        }
        newPanel.onCommandN = { [weak self] in
            guard let self else { return }
            guard self.snippetModule.isActive(in: self.router, for: self.viewModel.query) else { return }
            self.hide()
            self.snippetModule.showEditor {
                Task { await self.snippetModule.refreshSnippets() }
            }
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
        newPanel.onTab = { [weak viewModel] in
            guard let viewModel else { return }
            Task {
                if let newQuery = await viewModel.tabComplete() {
                    viewModel.query = newQuery
                }
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
        let visibleRows = hasPreview
            ? PanelLayout.maxVisibleRows
            : min(results.count, PanelLayout.maxVisibleRows)
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

extension PanelManager: PanelContext {
    func pasteAndActivate(target: NSRunningApplication?) {
        target?.activate()
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            KeyboardUtils.simulatePaste()
            // Clear previousApp after paste is complete
            await MainActor.run {
                self.clearPreviousApp()
            }
        }
    }

    func hidePanel() {
        hide()
    }

    func pasteText(_ text: String) {
        // Save previousApp before anything else clears it
        let target = previousApp

        // Write to clipboard
        let pb = ClipboardStore.prepareTransientPasteboard(types: [.string])
        pb.setString(text, forType: .string)

        // Activate target app and paste (hide is handled by the caller/onReturn)
        pasteAndActivate(target: target)
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
        .background(.ultraThickMaterial)
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
                            shortcutNumber: index < PanelLayout.maxShortcutKeys ? index + 1 : nil,
                            isPendingDelete: index == viewModel.pendingDeleteIndex
                        )
                        .id(result.id)
                        .onTapGesture { handleRowTap(index: index) }
                    }
                }
                // Rows are fixed-height; derive hovered index from y-coordinate.
                // Using .onContinuousHover (not .onHover) so stationary cursors
                // don't hijack keyboard selection when rows scroll under them.
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let point) = phase else { return }
                    let index = Int(point.y / PanelLayout.rowHeight)
                    guard viewModel.results.indices.contains(index),
                          viewModel.selectedIndex != index else { return }
                    viewModel.selectedIndex = index
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

    private func handleRowTap(index: Int) {
        guard viewModel.results.indices.contains(index) else { return }
        viewModel.selectedIndex = index
        if viewModel.confirm(modifiers: viewModel.activeModifiers) {
            onDismiss()
        } else {
            isSearchFieldFocused = true
        }
    }
}

private struct PreviewPane: View {
    let data: PreviewData

    var body: some View {
        switch data {
        case .text(let content):
            NativeTextPreview(text: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .html(let content):
            HTMLPreview(htmlContent: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let path, let description):
            VStack(spacing: 12) {
                CachedImageView(url: path, maxPixelSize: 512) {
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

/// A native NSTextView wrapped for SwiftUI, optimized for large emoji rendering.
private struct NativeTextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 18)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = .clear
        textView.drawsBackground = false

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.string = text
    }
}

/// A WKWebView wrapped for SwiftUI, used for HTML preview rendering.
private struct HTMLPreview: NSViewRepresentable {
    let htmlContent: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(htmlContent, baseURL: nil)
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
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
            let scaledSize = Int(CGFloat(maxPixelSize) * scale)
            nsImage = await ThumbnailCache.shared.loadThumbnail(for: url, maxPixelSize: scaledSize)
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
    var isPendingDelete: Bool = false

    private var subtitleText: String {
        if isPendingDelete {
            return "\(result.deleteSubtitle)?"
        }
        return isSelected ? result.displaySubtitle(for: activeModifiers) : result.subtitle
    }

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
                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(isPendingDelete ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
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
