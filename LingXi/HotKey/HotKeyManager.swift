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
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    // Static reference required to bridge Carbon C callback to Swift instance
    private static var instance: HotKeyManager?
    var onHotKey: (() -> Void)?

    private var keyCode: UInt32
    private var modifiers: UInt32

    init(keyCode: UInt32 = AppSettings.defaultHotKeyKeyCode, modifiers: UInt32 = AppSettings.defaultHotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func start() {
        requestAccessibilityPermission()
        registerHotKey()
    }

    func stop() {
        unregisterHotKey()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        HotKeyManager.instance = nil
    }

    func updateHotKey(keyCode: UInt32, modifiers: UInt32) {
        guard keyCode != self.keyCode || modifiers != self.modifiers else { return }
        self.keyCode = keyCode
        self.modifiers = modifiers
        unregisterHotKey()
        registerHotKey()
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func registerHotKey() {
        HotKeyManager.instance = self

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C586B79), id: 1) // "LXky"

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

            let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
                Task { @MainActor in
                    HotKeyManager.instance?.onHotKey?()
                }
                return noErr
            }

            InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandlerRef)
        }

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("Failed to register hotkey: \(status)")
        }
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
