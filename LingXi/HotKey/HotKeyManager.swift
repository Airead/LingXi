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

    func start() {
        requestAccessibilityPermission()
        registerHotKey()
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        HotKeyManager.instance = nil
    }

    private func registerHotKey() {
        HotKeyManager.instance = self

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C586B79), id: 1) // "LXky"

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            Task { @MainActor in
                HotKeyManager.instance?.onHotKey?()
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandlerRef)

        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
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
