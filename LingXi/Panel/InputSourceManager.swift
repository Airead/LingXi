//
//  InputSourceManager.swift
//  LingXi
//
//  Created by fanrenhao on 2026/4/4.
//

import Carbon

@MainActor
final class InputSourceManager {
    private var savedInputSource: TISInputSource?
    private lazy var asciiSource: TISInputSource? = Self.findASCIICapableSource()

    func saveAndSwitchToASCII() {
        savedInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if let asciiSource {
            TISSelectInputSource(asciiSource)
        }
    }

    func restore() {
        guard let source = savedInputSource else { return }
        TISSelectInputSource(source)
        savedInputSource = nil
    }

    private static func findASCIICapableSource() -> TISInputSource? {
        let conditions: CFDictionary = [
            kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsASCIICapable!: true,
            kTISPropertyInputSourceIsSelectCapable!: true,
        ] as NSDictionary
        guard let sources = TISCreateInputSourceList(conditions, false)?.takeRetainedValue() as? [TISInputSource],
              let first = sources.first else {
            return nil
        }
        return first
    }
}
