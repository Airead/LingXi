import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum KeyboardUtils {
    private static let vkDelete: CGKeyCode = 51

    /// Send *count* backspace keystrokes via CGEvent.
    static func sendBackspaces(count: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: vkDelete, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vkDelete, keyDown: false)
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Simulate Cmd+V paste via CGEvent.
    static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
