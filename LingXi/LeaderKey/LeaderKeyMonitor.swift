import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Async callback interface for leader key UI events.
/// All methods are called asynchronously on the main thread.
@MainActor
protocol LeaderKeyMonitorDelegate: AnyObject {
    func leaderMonitorDidActivate(_ config: LeaderConfig)
    func leaderMonitorDidDeactivate()
    func leaderMonitorDidMatch(_ mapping: LeaderMapping)
}

/// Monitors global keyboard events via CGEventTap to detect leader key
/// sequences: modifier key press → sub-key press → modifier key release.
///
/// Config lookup and key matching happen synchronously on the event tap
/// thread using a lock-protected configs snapshot, so the tap callback
/// never blocks waiting for the main thread.
///
/// Runs on a dedicated background thread with its own CFRunLoop.
final class LeaderKeyMonitor: @unchecked Sendable {

    /// Must be set on the main thread. Always read via `DispatchQueue.main.async`
    /// from the event tap thread, so no additional synchronization is needed.
    weak var delegate: LeaderKeyMonitorDelegate?

    // MARK: - Lock-protected state (accessed from event tap thread)

    private let lock = NSLock()
    private var configs: [String: LeaderConfig] = [:]
    private var suppressed = false
    private var isActive = false
    private var activeTriggerKeycode: UInt16 = 0
    private var activeTriggerFlagBit: UInt64 = 0
    private var activeConfig: LeaderConfig?
    private var previousModFlags: UInt64 = 0
    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?

    // MARK: - Event tap resources

    private var thread: Thread?
    private nonisolated(unsafe) var retainedSelf: Unmanaged<LeaderKeyMonitor>?
    private let tapStopped = DispatchSemaphore(value: 0)

    // MARK: - Public API

    func updateConfigs(_ newConfigs: [String: LeaderConfig]) {
        lock.withLock { configs = newConfigs }
    }

    func start() {
        let shouldStart = lock.withLock { thread == nil }
        guard shouldStart else { return }
        let bg = Thread { [weak self] in
            self?.runEventTap()
        }
        bg.name = "io.github.airead.lingxi.LeaderKeyMonitor"
        bg.qualityOfService = .userInteractive
        bg.start()
        lock.withLock { thread = bg }
    }

    func stop() {
        let (tap, loop, hadThread): (CFMachPort?, CFRunLoop?, Bool) = lock.withLock {
            let t = eventTap
            let l = runLoop
            let had = thread != nil
            eventTap = nil
            runLoop = nil
            thread = nil
            deactivateLocked()
            previousModFlags = 0
            return (t, l, had)
        }

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }

        if hadThread {
            let result = tapStopped.wait(timeout: .now() + 2)
            if result == .timedOut {
                print("LeaderKeyMonitor: stop timed out waiting for tap thread")
            }
        }
    }

    func suppress() {
        let wasActive: Bool = lock.withLock {
            suppressed = true
            guard isActive else { return false }
            deactivateLocked()
            return true
        }
        if wasActive {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.leaderMonitorDidDeactivate()
            }
        }
    }

    func resume() {
        lock.withLock { suppressed = false }
    }

    // MARK: - CGEventTap setup

    private func runEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let retained = Unmanaged.passRetained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: LeaderKeyMonitor.eventTapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            print("LeaderKeyMonitor: failed to create event tap. Check accessibility permissions.")
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
        let monitor = Unmanaged<LeaderKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handleEvent(type: type, event: event)
    }

    // MARK: - Event handling

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock {
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                previousModFlags = CGEventSource.flagsState(.combinedSessionState).rawValue
            }
            return Unmanaged.passUnretained(event)
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue

        switch type {
        case .flagsChanged: return handleFlagsChanged(keycode: keycode, flags: flags, event: event)
        case .keyDown:      return handleKeyDown(keycode: keycode, flags: flags, event: event)
        case .keyUp:        return handleKeyUp(keycode: keycode, event: event)
        default:            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - FlagsChanged

    private func handleFlagsChanged(keycode: UInt16, flags: UInt64, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerName = LeaderKeycode.keycodeToModifierName[keycode],
              let info = LeaderKeycode.modifierKeys[triggerName] else {
            lock.withLock { previousModFlags = flags }
            return Unmanaged.passUnretained(event)
        }

        let action: FlagsAction = lock.withLock {
            let wasDown = (previousModFlags & info.flagBit) != 0
            let isDown = (flags & info.flagBit) != 0
            previousModFlags = flags

            if isDown && !wasDown {
                return onTriggerPressLocked(keyName: triggerName, keycode: keycode, flagBit: info.flagBit)
            } else if !isDown && wasDown {
                return onTriggerReleaseLocked(keycode: keycode)
            }
            return .passthrough
        }

        switch action {
        case .passthrough:
            return Unmanaged.passUnretained(event)
        case .activated(let config):
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.leaderMonitorDidActivate(config)
            }
            return Unmanaged.passUnretained(event)
        case .deactivated:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.leaderMonitorDidDeactivate()
            }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - KeyDown

    private func handleKeyDown(keycode: UInt16, flags: UInt64, event: CGEvent) -> Unmanaged<CGEvent>? {
        let result: KeyDownResult = lock.withLock {
            guard isActive else { return .passthrough }

            // Esc dismisses leader mode
            if keycode == UInt16(kVK_Escape) {
                deactivateLocked()
                return .dismissed
            }

            guard let keyName = LeaderKeycode.keycodeToName[keycode] else {
                return .swallow
            }

            // Block if extra modifiers are held (besides the trigger modifier)
            let extraMods = flags & (
                CGEventFlags.maskCommand.rawValue |
                CGEventFlags.maskControl.rawValue |
                CGEventFlags.maskAlternate.rawValue
            )
            if (extraMods & ~activeTriggerFlagBit) != 0 {
                return .swallow
            }

            if let config = activeConfig,
               let mapping = config.mappingsByKey[keyName] {
                deactivateLocked()
                return .matched(mapping)
            }

            return .swallow
        }

        switch result {
        case .passthrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .dismissed:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.leaderMonitorDidDeactivate()
            }
            return nil
        case .matched(let mapping):
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.leaderMonitorDidMatch(mapping)
            }
            return nil
        }
    }

    // MARK: - KeyUp

    private func handleKeyUp(keycode: UInt16, event: CGEvent) -> Unmanaged<CGEvent>? {
        let active = lock.withLock { isActive }
        if active, LeaderKeycode.keycodeToName[keycode] != nil {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Trigger logic (called within lock)

    private func onTriggerPressLocked(keyName: String, keycode: UInt16, flagBit: UInt64) -> FlagsAction {
        guard !isActive, !suppressed, let config = configs[keyName] else {
            return .passthrough
        }
        isActive = true
        activeTriggerKeycode = keycode
        activeTriggerFlagBit = flagBit
        activeConfig = config
        return .activated(config)
    }

    private func onTriggerReleaseLocked(keycode: UInt16) -> FlagsAction {
        guard isActive, activeTriggerKeycode == keycode else { return .passthrough }
        deactivateLocked()
        return .deactivated
    }

    private func deactivateLocked() {
        isActive = false
        activeTriggerKeycode = 0
        activeTriggerFlagBit = 0
        activeConfig = nil
    }
}

// MARK: - Internal result types

private enum FlagsAction {
    case passthrough
    case activated(LeaderConfig)
    case deactivated
}

private enum KeyDownResult {
    case passthrough
    case swallow
    case dismissed
    case matched(LeaderMapping)
}
