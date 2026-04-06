//
//  LingXiCaptureService.swift
//  LingXiCaptureService
//

import AppKit
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// XPC service implementation that performs screen capture in an isolated process.
/// When the service is idle, the system can terminate it, reclaiming all ScreenCaptureKit memory.
class LingXiCaptureService: NSObject, LingXiCaptureServiceProtocol {

    func captureFullScreen(displayID: UInt32, excludeBundleID: String, pixelWidth: UInt32, pixelHeight: UInt32, reply: @escaping (Data?) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { UInt32($0.displayID) == displayID })
                    ?? content.displays.first
                else {
                    reply(nil)
                    return
                }

                let filter = buildFilter(display: display, content: content, excludeBundleID: excludeBundleID)
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

                let pngData = extractPNGData(from: sampleBuffer)
                reply(pngData)
            } catch {
                NSLog("[CaptureService] Capture failed: \(error)")
                reply(nil)
            }
        }
    }

    func recognizeText(atURL url: URL, reply: @escaping (String) -> Void) {
        Task {
            let handler = VNImageRequestHandler(url: url)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            do {
                try handler.perform([request])
            } catch {
                NSLog("[CaptureService] OCR failed: \(error)")
                reply("")
                return
            }
            guard let results = request.results else {
                reply("")
                return
            }
            let text = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            reply(text)
        }
    }

    // MARK: - Private

    private func buildFilter(
        display: SCDisplay,
        content: SCShareableContent,
        excludeBundleID: String
    ) -> SCContentFilter {
        if !excludeBundleID.isEmpty {
            let excludedApps = content.applications.filter {
                $0.bundleIdentifier == excludeBundleID
            }
            if !excludedApps.isEmpty {
                return SCContentFilter(
                    display: display,
                    excludingApplications: excludedApps,
                    exceptingWindows: []
                )
            }
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    private static let ciContext = CIContext()

    private func extractPNGData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
