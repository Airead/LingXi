//
//  InputSourceManagerTests.swift
//  LingXiTests
//
//  Created by fanrenhao on 2026/4/4.
//

import Carbon
import Testing

@testable import LingXi

private func inputSourceID(_ source: TISInputSource) -> String {
    unsafeBitCast(
        TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
        to: CFString.self
    ) as String
}

@MainActor
struct InputSourceManagerTests {
    @Test func saveAndSwitchToASCII_switchesToASCIICapableSource() {
        let manager = InputSourceManager()
        manager.saveAndSwitchToASCII()

        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let isASCII = unsafeBitCast(
            TISGetInputSourceProperty(current, kTISPropertyInputSourceIsASCIICapable),
            to: CFBoolean.self
        )
        #expect(CFBooleanGetValue(isASCII))
    }

    @Test func restore_returnsToPreviousInputSource() {
        let manager = InputSourceManager()
        let originalID = inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())

        manager.saveAndSwitchToASCII()
        manager.restore()

        let restoredID = inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        #expect(restoredID == originalID)
    }

    @Test func restore_withoutSave_doesNothing() {
        let manager = InputSourceManager()
        let beforeID = inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())

        manager.restore()

        let afterID = inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        #expect(afterID == beforeID)
    }
}
