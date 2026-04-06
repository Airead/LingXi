//
//  ScreenCaptureService.swift
//  LingXi
//

import AppKit
import CoreMedia
import ImageIO
import ScreenCaptureKit
import Synchronization
import UniformTypeIdentifiers

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

/// Provides screen capture in-process via ScreenCaptureKit and OCR via an XPC service
/// to isolate Vision framework memory. When the XPC service is idle, the system
/// terminates it and reclaims all OCR-related memory.
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
    func requestPermission() -> Bool {
        if hasPermission() { return true }
        CGRequestScreenCaptureAccess()
        return hasPermission()
    }

    // MARK: - In-process Capture (ScreenCaptureKit)

    /// Capture full screen as CGImage directly in the main process via ScreenCaptureKit.
    @concurrent
    func captureFullScreen(displayID: CGDirectDisplayID, content: SCShareableContent, pixelWidth: UInt32 = 0, pixelHeight: UInt32 = 0) async throws -> CGImage {
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
        else {
            throw ScreenCaptureError.captureFailed("No display found")
        }

        let excludedApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter: SCContentFilter = if !excludedApps.isEmpty {
            SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        } else {
            SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        if pixelWidth > 0 && pixelHeight > 0 {
            config.width = Int(pixelWidth)
            config.height = Int(pixelHeight)
        }

        let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter,
            configuration: config
        )

        guard let cgImage = Self.extractCGImage(from: sampleBuffer) else {
            throw ScreenCaptureError.captureFailed("Failed to create CGImage from sample buffer")
        }
        await DebugLog.logMemory("captureFullScreen done (\(cgImage.width)x\(cgImage.height))")
        return cgImage
    }

    /// Encode a CGImage as PNG data.
    private nonisolated static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private nonisolated static func extractCGImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        // BGRA → create CGImage via CGContext, then copy pixel data to decouple from the buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let tempImage = context.makeImage() else { return nil }

        // Copy into independent backing store so the CVPixelBuffer can be freed
        guard let copyContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        copyContext.draw(tempImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return copyContext.makeImage()
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

    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    /// Get the CGDirectDisplayID for the given screen.
    func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[Self.screenNumberKey] as? CGDirectDisplayID) ?? CGMainDisplayID()
    }

    /// Find the CGDirectDisplayID for the display containing the given screen point.
    func displayID(at point: CGPoint) -> CGDirectDisplayID {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &displayID, &count)
        return count > 0 ? displayID : CGMainDisplayID()
    }

    // MARK: - Crop

    /// Crop a CGImage to the specified region, copying pixel data into independent memory.
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
        // cropping(to:) shares the source backing store; copy into independent memory
        // so the full-screen source image can be freed.
        guard let cropped = image.cropping(to: pixelRect) else { return nil }
        let colorSpace = cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: cropped.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: cropped.bitmapInfo.rawValue
        ) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    // MARK: - Clipboard

    /// Copy a CGImage as PNG to the specified pasteboard.
    nonisolated func copyToClipboard(cgImage: CGImage, pasteboard: NSPasteboard = .general) {
        guard let pngData = Self.encodePNG(cgImage) else {
            DebugLog.log("[ScreenCaptureService] Failed to encode CGImage as PNG for clipboard")
            return
        }
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    // MARK: - XPC Connection (OCR)

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
            Task { @MainActor in
                DebugLog.log("[ScreenCaptureService] XPC connection interrupted; service will restart automatically")
            }
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
