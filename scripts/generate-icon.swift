import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate-icon.swift source.svg output.png\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let symbol = NSImage(contentsOf: sourceURL) else {
    fputs("unable to load source SVG\n", stderr)
    exit(3)
}

let pixelSize = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(4) }

bitmap.size = NSSize(width: pixelSize, height: pixelSize)
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(5) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()

let tileRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 205, yRadius: 205)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
shadow.shadowBlurRadius = 42
shadow.shadowOffset = NSSize(width: 0, height: -20)
shadow.set()
NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.52, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.31, green: 0.18, blue: 0.88, alpha: 1)
])!.draw(in: tile, angle: -52)

NSGraphicsContext.current?.saveGraphicsState()
tile.addClip()
let glowRect = NSRect(x: 120, y: 510, width: 760, height: 500)
NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
    .draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
NSGraphicsContext.current?.restoreGraphicsState()

let symbolCanvas = NSImage(size: NSSize(width: 560, height: 560))
symbolCanvas.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
symbol.draw(in: NSRect(x: 0, y: 0, width: 560, height: 560), from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 560, height: 560).fill(using: .sourceIn)
symbolCanvas.unlockFocus()

let symbolShadow = NSShadow()
symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
symbolShadow.shadowBlurRadius = 16
symbolShadow.shadowOffset = NSSize(width: 0, height: -8)
symbolShadow.set()
symbolCanvas.draw(in: NSRect(x: 232, y: 232, width: 560, height: 560))

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(6) }
try png.write(to: outputURL, options: .atomic)
