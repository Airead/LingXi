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
///
/// NOTE: Uses NSLock + @unchecked Sendable instead of Swift actor because
/// the CGEventTap callback is a C function pointer that requires synchronous
/// access — an actor's async isolation would deadlock the event tap.
final class LeaderKeyMonitor: @unchecked Sendable {

    /// Must be set on the main thread. Always read via `DispatchQueue.main.async`
    /// from the event tap thread, so no additional synchronization is needed.
    weak var delegate: LeaderKeyMonitorDelegate?

    // MARK: - Lock-protected state (accessed from event tap thread)

    private let lock = NSLock()
    private var configs: [String: LeaderConfig] = [:]
    private var suppressed = false
    private var state: LeaderState = .idle
    private var subKeyMatched = false
    private var swallowedKeycodes: Set<UInt16> = []
    private var pressTimestamp: UInt64 = 0
    private static let holdThresholdNanos: UInt64 = 300_000_000 // 300ms
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
        let bg: Thread? = lock.withLock {
            guard thread == nil else { return nil }
            let t = Thread { [weak self] in
                self?.runEventTap()
            }
            t.name = "io.github.airead.lingxi.LeaderKeyMonitor"
            t.qualityOfService = .userInteractive
            thread = t
            return t
        }
        bg?.start()
    }

    func stop() {
        let (tap, loop, hadThread, wasActive): (CFMachPort?, CFRunLoop?, Bool, Bool) = lock.withLock {
            let t = eventTap
            let l = runLoop
            let had = thread != nil
            let active = state != .idle
            eventTap = nil
            runLoop = nil
            thread = nil
            deactivateLocked()
            previousModFlags = 0
            return (t, l, had, active)
        }

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }

        if wasActive {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.leaderMonitorDidDeactivate()
            }
        }

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
            guard state != .idle else { return false }
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
                return onTriggerReleaseLocked(flagBit: info.flagBit)
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
        case .switched(let config):
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.leaderMonitorDidDeactivate()
                self?.delegate?.leaderMonitorDidActivate(config)
            }
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - KeyDown

    private func handleKeyDown(keycode: UInt16, flags: UInt64, event: CGEvent) -> Unmanaged<CGEvent>? {
        let result: KeyDownResult = lock.withLock {
            guard state != .idle else { return .passthrough }

            // Esc dismisses leader mode
            if keycode == UInt16(kVK_Escape) {
                deactivateLocked()
                swallowedKeycodes.insert(keycode)
                return .dismissed
            }

            guard let keyName = LeaderKeycode.keycodeToName[keycode] else {
                swallowedKeycodes.insert(keycode)
                return .swallow
            }

            // Block if extra modifiers are held (besides the trigger modifier)
            let extraMods = flags & (
                CGEventFlags.maskCommand.rawValue |
                CGEventFlags.maskControl.rawValue |
                CGEventFlags.maskAlternate.rawValue |
                CGEventFlags.maskShift.rawValue
            )
            if (extraMods & ~activeTriggerFlagBit) != 0 {
                return .swallow
            }

            if let config = activeConfig,
               let mapping = config.mappingsByKey[keyName] {
                swallowedKeycodes.insert(keycode)
                if state == .toggled {
                    deactivateLocked()
                    return .matchedAndDismissed(mapping)
                }
                // holding: execute but stay active for more sub-keys
                subKeyMatched = true
                return .matched(mapping)
            }

            swallowedKeycodes.insert(keycode)
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
        case .matchedAndDismissed(let mapping):
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.leaderMonitorDidMatch(mapping)
                self?.delegate?.leaderMonitorDidDeactivate()
            }
            return nil
        }
    }

    // MARK: - KeyUp

    private func handleKeyUp(keycode: UInt16, event: CGEvent) -> Unmanaged<CGEvent>? {
        let shouldSwallow: Bool = lock.withLock {
            swallowedKeycodes.remove(keycode) != nil
        }
        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: - Trigger logic (called within lock)

    private func onTriggerPressLocked(keyName: String, keycode: UInt16, flagBit: UInt64) -> FlagsAction {
        // In toggled mode, pressing any trigger closes the panel
        if state == .toggled {
            let wasSameTrigger = activeTriggerKeycode == keycode
            deactivateLocked()
            if wasSameTrigger {
                return .deactivated
            }
            // Different trigger: close current, then try to activate new one below
            if !suppressed, let config = configs[keyName] {
                state = .holding
                subKeyMatched = false
                pressTimestamp = DispatchTime.now().uptimeNanoseconds
                activeTriggerKeycode = keycode
                activeTriggerFlagBit = flagBit
                activeConfig = config
                return .switched(config)
            }
            return .deactivated
        }
        guard state == .idle, !suppressed, let config = configs[keyName] else {
            return .passthrough
        }
        state = .holding
        subKeyMatched = false
        pressTimestamp = DispatchTime.now().uptimeNanoseconds
        activeTriggerKeycode = keycode
        activeTriggerFlagBit = flagBit
        activeConfig = config
        return .activated(config)
    }

    private func onTriggerReleaseLocked(flagBit: UInt64) -> FlagsAction {
        guard state == .holding, activeTriggerFlagBit == flagBit else { return .passthrough }
        let elapsed = DispatchTime.now().uptimeNanoseconds - pressTimestamp
        if subKeyMatched || elapsed >= Self.holdThresholdNanos {
            // Sub-keys were pressed or held long enough — close panel
            deactivateLocked()
            return .deactivated
        }
        // Quick tap with no sub-key — enter toggle mode, panel stays open
        state = .toggled
        return .passthrough
    }

    private func deactivateLocked() {
        state = .idle
        subKeyMatched = false
        // Note: swallowedKeycodes is NOT cleared here — pending keyUp
        // events arrive after deactivation and must still be swallowed.
        pressTimestamp = 0
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
    /// Deactivated the previous config, then activated a new one.
    case switched(LeaderConfig)
}

private enum LeaderState {
    case idle
    case holding
    case toggled
}

private enum KeyDownResult {
    case passthrough
    case swallow
    case dismissed
    case matched(LeaderMapping)
    case matchedAndDismissed(LeaderMapping)
}
