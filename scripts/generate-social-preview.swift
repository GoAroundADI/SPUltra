#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

let width = 1280
let height = 640
let canvas = NSImage(size: NSSize(width: width, height: height))

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func roundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func drawText(
    _ value: String,
    at point: NSPoint,
    font: NSFont,
    color: NSColor,
    width: CGFloat = 900,
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    value.draw(
        in: NSRect(x: point.x, y: point.y, width: width, height: font.pointSize * 1.5),
        withAttributes: attributes
    )
}

canvas.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Unable to create graphics context")
}

let background = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0x080B14).cgColor, color(0x11172A).cgColor, color(0x17152F).cgColor] as CFArray,
    locations: [0, 0.58, 1]
)!
context.drawLinearGradient(
    background,
    start: CGPoint(x: 0, y: height),
    end: CGPoint(x: width, y: 0),
    options: []
)

context.saveGState()
context.setShadow(offset: .zero, blur: 90, color: color(0x3C67FF, alpha: 0.46).cgColor)
context.setFillColor(color(0x315DFF, alpha: 0.24).cgColor)
context.fillEllipse(in: CGRect(x: 44, y: 136, width: 360, height: 360))
context.restoreGState()

context.saveGState()
context.setShadow(offset: .zero, blur: 110, color: color(0x7B4DFF, alpha: 0.36).cgColor)
context.setFillColor(color(0x724AF5, alpha: 0.18).cgColor)
context.fillEllipse(in: CGRect(x: 970, y: 360, width: 300, height: 300))
context.restoreGState()

roundedRect(
    NSRect(x: 42, y: 42, width: 1196, height: 556),
    radius: 34,
    fill: color(0xFFFFFF, alpha: 0.025),
    stroke: color(0xFFFFFF, alpha: 0.10)
)

let iconRect = NSRect(x: 104, y: 196, width: 248, height: 248)
context.saveGState()
context.setShadow(offset: NSSize(width: 0, height: -18), blur: 38, color: color(0x315DFF, alpha: 0.45).cgColor)
if let icon = NSImage(contentsOfFile: "docs/images/icon.png") {
    icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
} else {
    roundedRect(iconRect, radius: 58, fill: color(0x536DFE))
}
context.restoreGState()

let titleFont = NSFont.systemFont(ofSize: 72, weight: .bold)
let subtitleFont = NSFont.systemFont(ofSize: 31, weight: .semibold)
let detailFont = NSFont.systemFont(ofSize: 23, weight: .medium)
let pillFont = NSFont.systemFont(ofSize: 18, weight: .semibold)

drawText("SP Ultra", at: NSPoint(x: 414, y: 405), font: titleFont, color: .white)
drawText(
    "SFTP · SCP 远程文件传输",
    at: NSPoint(x: 419, y: 350),
    font: subtitleFont,
    color: color(0xE5E9FF)
)
drawText(
    "Apple Silicon 原生  ·  SecureFX 平替产品",
    at: NSPoint(x: 419, y: 302),
    font: detailFont,
    color: color(0x9EADD4)
)

let divider = NSBezierPath()
divider.move(to: NSPoint(x: 419, y: 273))
divider.line(to: NSPoint(x: 1118, y: 273))
color(0x6A78FF, alpha: 0.55).setStroke()
divider.lineWidth = 2
divider.stroke()

let pills = ["稳定传输", "断点续传", "远程编辑", "权限管理"]
var pillX: CGFloat = 419
for label in pills {
    let labelWidth = (label as NSString).size(withAttributes: [.font: pillFont]).width
    let pillWidth = labelWidth + 38
    roundedRect(
        NSRect(x: pillX, y: 207, width: pillWidth, height: 43),
        radius: 21.5,
        fill: color(0xFFFFFF, alpha: 0.055),
        stroke: color(0x8796FF, alpha: 0.24)
    )
    drawText(
        label,
        at: NSPoint(x: pillX, y: 216),
        font: pillFont,
        color: color(0xD7DEFF),
        width: pillWidth,
        alignment: .center
    )
    pillX += pillWidth + 14
}

drawText(
    "macOS 15+",
    at: NSPoint(x: 421, y: 126),
    font: NSFont.systemFont(ofSize: 17, weight: .medium),
    color: color(0x7E8CB4)
)

canvas.unlockFocus()

guard
    let tiff = canvas.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Unable to encode PNG")
}

let output = URL(fileURLWithPath: "docs/images/social-preview.png")
try png.write(to: output, options: .atomic)

// `NSImage.lockFocus()` uses the display backing scale on Retina Macs. Normalize
// the committed GitHub social preview to its documented 1280×640 pixel size.
let resizer = Process()
resizer.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
resizer.arguments = ["-z", "640", "1280", output.path]
resizer.standardOutput = FileHandle.nullDevice
resizer.standardError = FileHandle.nullDevice
try resizer.run()
resizer.waitUntilExit()
guard resizer.terminationStatus == 0 else {
    fatalError("Unable to normalize social preview dimensions")
}

print(output.path)
