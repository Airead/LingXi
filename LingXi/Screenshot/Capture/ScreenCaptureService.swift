//
//  ScreenCaptureService.swift
//  LingXi
//

import AppKit
import Synchronization

/// Errors that can occur during screen capture operations.
enum ScreenCaptureError: Error, LocalizedError {
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .captureFailed(let message):
            "Capture failed: \(message)"
        }
    }
}

/// XPC service name — must match the XPC service's bundle identifier.
private let captureServiceName = "io.github.airead.lingxi.CaptureService"

/// Coordinates screen capture via an XPC service to isolate ScreenCaptureKit memory.
/// When the XPC service is idle, the system terminates it and reclaims all memory.
@available(macOS 15.0, *)
@MainActor
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    private var connection: NSXPCConnection?
    private var idleTask: Task<Void, Never>?

    private init() {}

    // MARK: - Permission

    /// Check whether screen recording permission is currently granted.
    nonisolated func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission.
    /// Uses only CoreGraphics APIs to avoid loading ScreenCaptureKit into the main process.
    func requestPermission() -> Bool {
        if hasPermission() { return true }
        CGRequestScreenCaptureAccess()
        return hasPermission()
    }

    // MARK: - Capture via XPC

    /// Capture full screen via XPC service and return PNG data.
    func captureFullScreen(displayID: CGDirectDisplayID) async throws -> Data {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        defer { scheduleIdleDisconnect() }

        return try await withProxy { proxy, resumer in
            proxy.captureFullScreen(displayID: UInt32(displayID), excludeBundleID: bundleID) { data in
                if let data {
                    resumer.resume(returning: data)
                } else {
                    resumer.resume(throwing: ScreenCaptureError.captureFailed("XPC service returned nil"))
                }
            }
        }
    }

    /// Perform OCR on an image file via XPC service.
    func recognizeText(at url: URL) async throws -> String {
        defer { scheduleIdleDisconnect() }

        return try await withProxy { proxy, resumer in
            proxy.recognizeText(atURL: url) { text in
                resumer.resume(returning: text)
            }
        }
    }

    // MARK: - Idle Disconnect

    private func scheduleIdleDisconnect() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            connection?.invalidate()
            connection = nil
        }
    }

    // MARK: - Display Helpers

    /// Find the CGDirectDisplayID for the display containing the given screen point.
    func displayID(at point: CGPoint) -> CGDirectDisplayID {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &displayID, &count)
        return count > 0 ? displayID : CGMainDisplayID()
    }

    /// Get the backing scale factor for a display.
    func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        screen(for: displayID)?.backingScaleFactor ?? 2.0
    }

    /// Get the screen frame (in Cocoa coordinates) for a display.
    func screenFrame(for displayID: CGDirectDisplayID) -> CGRect {
        screen(for: displayID)?.frame ?? CGDisplayBounds(displayID)
    }

    /// Find the NSScreen matching a CGDirectDisplayID.
    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    // MARK: - Crop

    /// Crop a CGImage to the specified region.
    nonisolated func cropImage(
        _ image: CGImage,
        to rect: CGRect,
        screenFrame: CGRect,
        scaleFactor: CGFloat
    ) -> CGImage? {
        let flippedY = screenFrame.height - rect.origin.y - rect.height
        let pixelRect = CGRect(
            x: ceil(rect.origin.x * scaleFactor),
            y: ceil(flippedY * scaleFactor),
            width: ceil(rect.width * scaleFactor),
            height: ceil(rect.height * scaleFactor)
        )
        return image.cropping(to: pixelRect)
    }

    // MARK: - Clipboard

    /// Copy PNG data to the specified pasteboard.
    nonisolated func copyToClipboard(pngData: Data, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    // MARK: - Private

    /// Ensures a continuation is resumed at most once, preventing crashes from double-resume
    /// when both the XPC error handler and the reply block fire.
    private final class OnceResumer<T>: Sendable {
        private let state: Mutex<CheckedContinuation<T, any Error>?>

        init(_ continuation: CheckedContinuation<T, any Error>) {
            self.state = Mutex(continuation)
        }

        func resume(returning value: T) {
            let c = state.withLock { val in let c = val; val = nil; return c }
            c?.resume(returning: value)
        }

        func resume(throwing error: any Error) {
            let c = state.withLock { val in let c = val; val = nil; return c }
            c?.resume(throwing: error)
        }
    }

    private func withProxy<T>(
        _ body: @escaping (any LingXiCaptureServiceProtocol, OnceResumer<T>) -> Void
    ) async throws -> T {
        let conn = ensureConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = OnceResumer(continuation)
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                resumer.resume(throwing: ScreenCaptureError.captureFailed("XPC error: \(error)"))
            }) as? LingXiCaptureServiceProtocol else {
                resumer.resume(throwing: ScreenCaptureError.captureFailed("Failed to obtain XPC proxy"))
                return
            }
            body(proxy, resumer)
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let existing = connection {
            return existing
        }
        let conn = NSXPCConnection(serviceName: captureServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: (any LingXiCaptureServiceProtocol).self)
        conn.interruptionHandler = {
            NSLog("[ScreenCaptureService] XPC connection interrupted; service will restart automatically")
        }
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
            }
        }
        conn.resume()
        connection = conn
        return conn
    }
}
