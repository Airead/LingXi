#!/usr/bin/env swift

/// Generate DMG volume icon (.icns) by reusing the app icon at 1024x1024
/// and converting it via iconutil.

import AppKit
import CoreGraphics
import Foundation

let outputDir = "resources"
let outputPng = "\(outputDir)/dmg-volume.png"
let outputIcns = "\(outputDir)/dmg-volume.icns"
let sourceIcon = "LingXi/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

guard fm.fileExists(atPath: sourceIcon) else {
    print("ERROR: \(sourceIcon) not found.")
    exit(1)
}

guard let sourceImage = NSImage(contentsOfFile: sourceIcon) else {
    fatalError("Failed to load \(sourceIcon)")
}

let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourceIcon))
try sourceData.write(to: URL(fileURLWithPath: outputPng))
print("Copied \(outputPng)")

let iconsetDir = "\(outputDir)/dmg-volume.iconset"
if fm.fileExists(atPath: iconsetDir) {
    try fm.removeItem(atPath: iconsetDir)
}
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let colorSpace = CGColorSpaceCreateDeviceRGB()

for spec in iconSizes {
    guard let ctx = CGContext(
        data: nil,
        width: spec.pixels, height: spec.pixels,
        bitsPerComponent: 8,
        bytesPerRow: spec.pixels * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { continue }

    ctx.interpolationQuality = .high

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: spec.pixels, height: spec.pixels),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let resized = ctx.makeImage() else { continue }

    let path = "\(iconsetDir)/\(spec.name)"
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL,
        "public.png" as CFString, 1, nil
    ) else { continue }
    CGImageDestinationAddImage(dest, resized, nil)
    CGImageDestinationFinalize(dest)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir, "-o", outputIcns]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    let fileSize = (try? fm.attributesOfItem(atPath: outputIcns)[.size] as? Int) ?? 0
    print("Generated \(outputIcns) (\(fileSize / 1024) KB)")
} else {
    print("ERROR: iconutil failed with status \(process.terminationStatus)")
    exit(1)
}

try? fm.removeItem(atPath: iconsetDir)
print("Done!")
