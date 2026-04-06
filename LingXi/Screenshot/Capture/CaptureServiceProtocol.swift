//
//  CaptureServiceProtocol.swift
//  LingXi
//
//  Identical copy of the XPC service protocol.
//  Both sides must define the same @objc protocol for NSXPCInterface.
//

import Foundation

/// Protocol for the screen capture and image processing XPC service.
/// Both the service and the host app must have an identical copy of this protocol.
@objc protocol LingXiCaptureServiceProtocol {
    /// Capture full screen at native resolution and return PNG data.
    /// - Parameters:
    ///   - displayID: The CGDirectDisplayID of the display to capture.
    ///   - excludeBundleID: Bundle ID of the app to exclude from capture. Pass empty string for none.
    ///   - reply: PNG data on success, nil on failure.
    func captureFullScreen(displayID: UInt32, excludeBundleID: String, reply: @escaping @Sendable (Data?) -> Void)

    /// Perform OCR on an image file and return recognized text.
    /// - Parameters:
    ///   - url: File URL of the image to recognize.
    ///   - reply: Recognized text, or empty string on failure.
    func recognizeText(atURL url: URL, reply: @escaping @Sendable (String) -> Void)
}
