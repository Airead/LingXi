import AppKit
import Foundation

/// Auto-expand snippet keywords as the user types.
///
/// Monitors keystrokes via a CGEventTap (listen-only), maintains a rolling
/// character buffer, and replaces matched keywords with snippet content
/// by sending backspace events followed by a clipboard paste.
final class SnippetExpander: @unchecked Sendable {

    // MARK: - Constants

    private static let maxBuffer = 128

    private enum Timing {
        /// Delay after sending backspaces to let the target app process them.
        static let postBackspace: TimeInterval = 0.05
        /// Delay after setting pasteboard before simulating Cmd+V.
        static let postPasteboard: TimeInterval = 0.05
        /// Delay after paste to let the target app consume before restoring clipboard.
        static let postPaste: TimeInterval = 0.10
    }

    /// Navigation/control keycodes that reset the buffer because they move
    /// the cursor or discard input, breaking any in-progress keyword sequence.
    private static let clearKeycodes: Set<Int64> = [
        36,  // return
        48,  // tab
        51,  // delete (backspace)
        53,  // escape
        76,  // enter (numpad)
        117, // forward delete
        123, // left arrow
        124, // right arrow
        125, // down arrow
        126, // up arrow
    ]

    // MARK: - State

    private let store: SnippetStore
    private let lock = NSLock()
    private var buffer = ""
    private var expanding = false
    private var suppressed = false

    /// Cached snapshot of expandable snippets (refreshed from actor).
    private var cachedSnippets: [Snippet] = []

    /// Event tap and run loop references (background thread only).
    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let tapStopped = DispatchSemaphore(value: 0)

    private let expansionQueue = DispatchQueue(
        label: "io.github.airead.lingxi.SnippetExpander.expansion",
        qos: .userInteractive
    )

    // MARK: - Init

    init(store: SnippetStore) {
        self.store = store
    }

    // MARK: - Public API

    func start() {
        guard thread == nil else { return }
        Task { await refreshSnippets() }
        let bg = Thread { [weak self] in
            self?.runEventTap()
        }
        bg.name = "io.github.airead.lingxi.SnippetExpander"
        bg.qualityOfService = .userInteractive
        bg.start()
        thread = bg
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let loop = runLoop {
            CFRunLoopStop(loop)
        }
        if thread != nil {
            _ = tapStopped.wait(timeout: .now() + 1.0)
        }
        // Release the retained reference from passRetained in runEventTap.
        if eventTap != nil {
            Unmanaged.passUnretained(self).release()
        }
        runLoop = nil
        eventTap = nil
        thread = nil
        lock.withLock {
            buffer = ""
            expanding = false
            cachedSnippets = []
        }
    }

    func suppress() {
        lock.withLock {
            suppressed = true
            buffer = ""
        }
    }

    func resume() {
        lock.withLock {
            suppressed = false
            buffer = ""
        }
        Task { await refreshSnippets() }
    }

    /// Refresh the cached snippet list from the actor.
    func refreshSnippets() async {
        let all = await store.allSnippets()
        let expandable = all.filter { $0.autoExpand && !$0.keyword.isEmpty }
        lock.withLock {
            cachedSnippets = expandable
        }
    }

    // MARK: - Testable internals

    /// Process a single keystroke. Returns the keyword that matched, if any.
    /// Extracted for unit testing — does not trigger actual expansion.
    @discardableResult
    func processKey(keycode: Int64, flags: CGEventFlags, character: String) -> String? {
        lock.withLock {
            processKeyLocked(keycode: keycode, flags: flags, character: character)
        }
    }

    /// Lock-free implementation called from within an existing lock region.
    private func processKeyLocked(keycode: Int64, flags: CGEventFlags, character: String) -> String? {
        let modMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        let hasModifier = !flags.intersection(modMask).isEmpty
        let isClearKey = Self.clearKeycodes.contains(keycode)

        guard !hasModifier, !isClearKey else {
            buffer = ""
            return nil
        }

        guard !character.isEmpty, character.allSatisfy({ $0.isPrintable }) else {
            return nil
        }

        buffer += character
        if buffer.count > Self.maxBuffer {
            buffer = String(buffer.suffix(Self.maxBuffer))
        }
        guard !suppressed else { return nil }

        for snippet in cachedSnippets {
            if buffer.hasSuffix(snippet.keyword) {
                return snippet.keyword
            }
        }
        return nil
    }

    /// Look up a snippet by keyword from the cache and return expansion info.
    func snippetForKeyword(_ keyword: String) -> (content: String, raw: Bool)? {
        let snippets = lock.withLock { cachedSnippets }
        guard let snippet = snippets.first(where: { $0.keyword == keyword }) else {
            return nil
        }
        let content: String
        if snippet.isRandom, !snippet.variants.isEmpty {
            content = snippet.variants.randomElement() ?? snippet.content
        } else {
            content = snippet.content
        }
        return (content, snippet.raw)
    }

    // MARK: - CGEventTap

    private func runEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: SnippetExpander.eventTapCallback,
            userInfo: Unmanaged.passRetained(self).toOpaque()
        ) else {
            print("SnippetExpander: failed to create event tap. Check accessibility permissions.")
            tapStopped.signal()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
        tapStopped.signal()
    }

    /// Static C-compatible callback required by CGEventTapCreate.
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let expander = Unmanaged<SnippetExpander>.fromOpaque(userInfo).takeUnretainedValue()
        expander.handleEvent(proxy: proxy, type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let char = extractUnicodeString(from: event)

        let keyword: String? = lock.withLock {
            // Always update the buffer so keystrokes are not lost during expansion.
            guard let kw = processKeyLocked(keycode: keycode, flags: flags, character: char) else {
                return nil
            }
            // Only trigger a new expansion when the previous one has finished.
            guard !expanding else { return nil }
            buffer = ""
            expanding = true
            return kw
        }

        guard let keyword else { return }

        guard let info = snippetForKeyword(keyword) else {
            lock.withLock { expanding = false }
            return
        }

        expansionQueue.async { [weak self] in
            self?.expand(keyword: keyword, content: info.content, raw: info.raw)
        }
    }

    // MARK: - Unicode extraction

    private func extractUnicodeString(from event: CGEvent) -> String {
        var length = 0
        var buf = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buf.count, actualStringLength: &length, unicodeString: &buf)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buf, count: min(length, buf.count))
    }

    // MARK: - Expansion

    private func expand(keyword: String, content: String, raw: Bool) {
        defer { lock.withLock { expanding = false } }

        let pb = NSPasteboard.general

        let expanded: String
        if raw {
            expanded = content
        } else {
            let clip = content.contains("{clipboard}")
                ? pb.string(forType: .string) : nil
            expanded = SnippetStore.expandPlaceholders(content, clipboard: clip)
        }

        // Save the current clipboard text so we can restore it after pasting.
        let savedClipboard = pb.string(forType: .string)

        KeyboardUtils.sendBackspaces(count: keyword.count)
        Thread.sleep(forTimeInterval: Timing.postBackspace)

        pb.clearContents()
        pb.setString(expanded, forType: .string)
        Thread.sleep(forTimeInterval: Timing.postPasteboard)

        KeyboardUtils.simulatePaste()

        // Restore the previous clipboard content after the paste is consumed.
        Thread.sleep(forTimeInterval: Timing.postPaste)
        pb.clearContents()
        if let savedClipboard {
            pb.setString(savedClipboard, forType: .string)
        }
    }
}

// MARK: - Character helpers

private extension Character {
    var isPrintable: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(scalar)
    }
}
