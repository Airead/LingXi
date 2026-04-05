//
//  HotKeyManager.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/2.
//

import Carbon
import Cocoa

@MainActor
final class HotKeyManager {
    private struct Registration {
        var keyCode: UInt32
        var modifiers: UInt32
        var hotKeyRef: EventHotKeyRef?
        var callback: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var nextId: UInt32 = 1
    // Static reference required to bridge Carbon C callback to Swift instance
    private static var instance: HotKeyManager?

    init() {}

    func start() {
        requestAccessibilityPermission()
        installEventHandler()
    }

    func stop() {
        for id in registrations.keys {
            unregisterCarbonHotKey(id: id)
        }
        registrations.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        HotKeyManager.instance = nil
    }

    /// Register a hotkey and return its ID. Pass keyCode=0 && modifiers=0 to skip registration.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> UInt32 {
        let id = nextId
        nextId += 1
        registrations[id] = Registration(keyCode: keyCode, modifiers: modifiers, callback: callback)
        if AppSettings.isHotKeySet(keyCode: keyCode, modifiers: modifiers) {
            registerCarbonHotKey(id: id)
        }
        return id
    }

    func update(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        guard var reg = registrations[id] else { return }
        guard keyCode != reg.keyCode || modifiers != reg.modifiers else { return }
        unregisterCarbonHotKey(id: id)
        reg.keyCode = keyCode
        reg.modifiers = modifiers
        registrations[id] = reg
        if AppSettings.isHotKeySet(keyCode: keyCode, modifiers: modifiers) {
            registerCarbonHotKey(id: id)
        }
    }

    func unregister(id: UInt32) {
        unregisterCarbonHotKey(id: id)
        registrations.removeValue(forKey: id)
    }

    // MARK: - Carbon integration

    private func installEventHandler() {
        HotKeyManager.instance = self

        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            Task { @MainActor in
                HotKeyManager.instance?.handleHotKey(id: hotKeyID.id)
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandlerRef)
    }

    private func handleHotKey(id: UInt32) {
        registrations[id]?.callback()
    }

    private func registerCarbonHotKey(id: UInt32) {
        guard var reg = registrations[id], reg.hotKeyRef == nil else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C586B79), id: id) // "LXky"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            reg.keyCode,
            reg.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            reg.hotKeyRef = ref
            registrations[id] = reg
        } else {
            print("Failed to register hotkey id=\(id): \(status)")
        }
    }

    private func unregisterCarbonHotKey(id: UInt32) {
        guard var reg = registrations[id], let ref = reg.hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        reg.hotKeyRef = nil
        registrations[id] = reg
    }

    private func requestAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            print("Accessibility permission requested. Please grant access and restart the app.")
        }
    }
}
