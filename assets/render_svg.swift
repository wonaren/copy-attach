import Foundation
import AppKit

let args = CommandLine.arguments
if args.count < 4 {
    print("Usage: swift render_svg.swift <input.svg> <output.png> <size>")
    exit(1)
}

let inputPath = args[1]
let outputPath = args[2]
guard let sizeVal = Double(args[3]) else {
    print("Invalid size")
    exit(1)
}

let size = NSSize(width: sizeVal, height: sizeVal)

guard let image = NSImage(contentsOfFile: inputPath) else {
    print("Failed to load SVG: \(inputPath)")
    exit(1)
}

// Set target size
image.size = size

// Create bitmap representation with transparent background
guard let bitmapRep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(sizeVal),
    pixelsHigh: Int(sizeVal),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    print("Failed to create NSBitmapImageRep")
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: bitmapRep)
NSGraphicsContext.current = context

// Clear to transparent
let rect = NSRect(origin: .zero, size: size)
NSColor.clear.set()
rect.fill()

// Draw the image
image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    print("Failed to convert to PNG")
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Successfully rendered \(outputPath) at size \(sizeVal)")
} catch {
    print("Failed to write PNG: \(error)")
    exit(1)
}
