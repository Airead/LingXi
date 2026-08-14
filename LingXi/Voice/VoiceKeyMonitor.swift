//
//  VoiceKeyMonitor.swift
//  LingXi
//

import CoreGraphics
import Foundation

/// Async callback interface for voice key (Fn) events.
/// All methods are called asynchronously on the main thread.
@MainActor
protocol VoiceKeyMonitorDelegate: AnyObject {
    func voiceKeyDidPress()
    func voiceKeyDidRelease()
    /// Another key was pressed while Fn was held — Fn is being used as a
    /// combo modifier (e.g. Fn+arrow), not as push-to-talk.
    func voiceKeyWasInterrupted()
    /// Z was pressed while Fn was held (WenZi-style preview-history
    /// shortcut). The Z key event is swallowed by the tap.
    func voiceKeyPreviewHistoryRequested()
}

/// What a keyDown during an Fn hold means, extracted as a pure function
/// for testability.
enum FnKeyDownAction: Equatable {
    case interrupt
    case previewHistory
}

/// Fn key state transition, extracted as a pure function for testability.
enum FnKeyTransition: Equatable {
    case pressed
    case released
}

/// Monitors the Fn key globally via a CGEventTap to drive push-to-talk
/// voice input. The tap is active only to swallow the Fn+Z preview-history
/// shortcut; every other event passes through unmodified.
///
/// Runs on a dedicated background thread with its own CFRunLoop.
///
/// NOTE: Uses NSLock + @unchecked Sendable instead of Swift actor because
/// the CGEventTap callback is a C function pointer that requires synchronous
/// access — an actor's async isolation would deadlock the event tap.
final class VoiceKeyMonitor: @unchecked Sendable {

    /// Must be set on the main thread. Always read via `DispatchQueue.main.async`
    /// from the event tap thread, so no additional synchronization is needed.
    weak var delegate: VoiceKeyMonitorDelegate?

    // MARK: - Lock-protected state (accessed from event tap thread)

    private let lock = NSLock()
    private var fnIsDown = false
    private var interruptedThisHold = false
    private var previewRequestedThisHold = false
    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?

    // MARK: - Event tap resources

    private var thread: Thread?
    private nonisolated(unsafe) var retainedSelf: Unmanaged<VoiceKeyMonitor>?
    private let tapStopped = DispatchSemaphore(value: 0)

    // MARK: - Fn transition (pure)

    nonisolated static let fnKeycode: UInt16 = 63
    /// kVK_ANSI_Z
    nonisolated static let zKeycode: UInt16 = 6
    nonisolated static let fnFlagMask = CGEventFlags.maskSecondaryFn.rawValue

    /// Meaning of a keyDown while Fn is held; nil when Fn is not held.
    nonisolated static func keyDownAction(keycode: UInt16, fnIsDown: Bool) -> FnKeyDownAction? {
        guard fnIsDown else { return nil }
        return keycode == zKeycode ? .previewHistory : .interrupt
    }

    /// Only flagsChanged events for the physical Fn key (keycode 63) are
    /// considered; other keys (e.g. arrow keys) also carry the Fn flag bit.
    nonisolated static func fnTransition(keycode: UInt16, flags: UInt64, wasDown: Bool) -> FnKeyTransition? {
        guard keycode == fnKeycode else { return nil }
        let isDown = (flags & fnFlagMask) != 0
        if isDown && !wasDown { return .pressed }
        if !isDown && wasDown { return .released }
        return nil
    }

    // MARK: - Public API

    func start() {
        let bg: Thread? = lock.withLock {
            guard thread == nil else { return nil }
            let t = Thread { [weak self] in
                self?.runEventTap()
            }
            t.name = "io.github.airead.lingxi.VoiceKeyMonitor"
            t.qualityOfService = .userInteractive
            thread = t
            return t
        }
        bg?.start()
    }

    func stop() {
        let (tap, loop, hadThread, wasDown): (CFMachPort?, CFRunLoop?, Bool, Bool) = lock.withLock {
            let t = eventTap
            let l = runLoop
            let had = thread != nil
            let down = fnIsDown
            eventTap = nil
            runLoop = nil
            thread = nil
            fnIsDown = false
            interruptedThisHold = false
            previewRequestedThisHold = false
            return (t, l, had, down)
        }

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }

        if wasDown {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.voiceKeyDidRelease()
            }
        }

        if hadThread {
            let result = tapStopped.wait(timeout: .now() + 2)
            if result == .timedOut {
                DebugLog.log("VoiceKeyMonitor: stop timed out waiting for tap thread")
            }
        }
    }

    // MARK: - CGEventTap setup

    private func runEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let retained = Unmanaged.passRetained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: VoiceKeyMonitor.eventTapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            DebugLog.log("VoiceKeyMonitor: failed to create event tap. Check accessibility permissions.")
            tapStopped.signal()
            return
        }

        retainedSelf = retained
        let currentLoop = CFRunLoopGetCurrent()!
        lock.withLock {
            eventTap = tap
            runLoop = currentLoop
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(currentLoop, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()

        // Background thread self-cleans after run loop exits
        retainedSelf?.release()
        retainedSelf = nil
        tapStopped.signal()
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<VoiceKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let swallow = monitor.handleEvent(type: type, event: event)
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: - Event handling

    /// Returns true when the event must be swallowed (Fn+Z only).
    private func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            handleTapDisabled()
            return false
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue

        switch type {
        case .flagsChanged:
            handleFlagsChanged(keycode: keycode, flags: flags)
            return false
        case .keyDown:
            return handleKeyDown(keycode: keycode)
        default:
            return false
        }
    }

    private func handleFlagsChanged(keycode: UInt16, flags: UInt64) {
        let transition: FnKeyTransition? = lock.withLock {
            guard let t = Self.fnTransition(keycode: keycode, flags: flags, wasDown: fnIsDown) else {
                return nil
            }
            switch t {
            case .pressed:
                fnIsDown = true
                interruptedThisHold = false
                previewRequestedThisHold = false
            case .released:
                fnIsDown = false
            }
            return t
        }

        switch transition {
        case .pressed:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.voiceKeyDidPress()
            }
        case .released:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.voiceKeyDidRelease()
            }
        case nil:
            break
        }
    }

    /// Returns true when the key event must be swallowed. Fn+Z requests the
    /// preview history (autorepeats stay swallowed but notify only once per
    /// hold); any other key marks Fn as a combo modifier.
    private func handleKeyDown(keycode: UInt16) -> Bool {
        var swallow = false
        let action: FnKeyDownAction? = lock.withLock {
            guard let action = Self.keyDownAction(keycode: keycode, fnIsDown: fnIsDown) else {
                return nil
            }
            switch action {
            case .previewHistory:
                swallow = true
                guard !previewRequestedThisHold else { return nil }
                previewRequestedThisHold = true
            case .interrupt:
                guard !interruptedThisHold else { return nil }
                interruptedThisHold = true
            }
            return action
        }
        switch action {
        case .previewHistory:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.voiceKeyPreviewHistoryRequested()
            }
        case .interrupt:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.voiceKeyWasInterrupted()
            }
        case nil:
            break
        }
        return swallow
    }

    /// macOS disables event taps that are too slow (or on user input for
    /// default taps). Re-enable and resync the Fn state from the system —
    /// a release lost during the gap would otherwise leave the recording
    /// running forever.
    private func handleTapDisabled() {
        let lostRelease: Bool = lock.withLock {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let actuallyDown = CGEventSource.flagsState(.combinedSessionState).rawValue & Self.fnFlagMask != 0
            if fnIsDown && !actuallyDown {
                fnIsDown = false
                return true
            }
            return false
        }
        if lostRelease {
            DebugLog.log("VoiceKeyMonitor: tap re-enabled, synthesizing lost Fn release")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.voiceKeyDidRelease()
            }
        }
    }
}
