#!/usr/bin/env swift
// Renders the Teleport app icon to a PNG using Core Graphics.
//
// Usage: swift make_icon.swift <output.png> [size]
//   size defaults to 1024.
//
// Design:
//   - Squircle (continuous-rounded square) filled with a brand gradient.
//   - Soft inner highlight for depth.
//   - Centered lightning bolt mark with a subtle drop-shadow.

import AppKit
import CoreGraphics

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: make_icon.swift <output.png> [size]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = CommandLine.arguments[1]
let size = CGFloat(Int(CommandLine.arguments.dropFirst(2).first ?? "1024") ?? 1024)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("Failed to create bitmap context\n".data(using: .utf8)!)
    exit(1)
}

// Helpers
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let bounds = CGRect(x: 0, y: 0, width: size, height: size)

// macOS Big Sur icon convention: leave ~10% padding around the squircle.
let inset = size * 0.085
let iconRect = bounds.insetBy(dx: inset, dy: inset)
let cornerRadius = iconRect.width * 0.225 // squircle-ish

// Squircle path
let squircle = CGPath(
    roundedRect: iconRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

// --- Drop shadow under the squircle ---
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -size * 0.012),
    blur: size * 0.045,
    color: color(0, 0, 0, 0.35)
)
ctx.addPath(squircle)
ctx.setFillColor(color(0.36, 0.55, 1.0))
ctx.fillPath()
ctx.restoreGState()

// --- Brand gradient fill ---
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        color(0.40, 0.30, 0.95),  // top-left  (purple)
        color(0.35, 0.55, 1.00),  // mid       (blue)
        color(0.20, 0.70, 1.00)   // bottom-right (cyan-blue)
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
    end:   CGPoint(x: iconRect.maxX, y: iconRect.minY),
    options: []
)

// Soft top highlight for glass look
let highlight = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        color(1, 1, 1, 0.22),
        color(1, 1, 1, 0.0)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    highlight,
    start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
    end:   CGPoint(x: iconRect.midX, y: iconRect.midY),
    options: []
)

// Subtle vignette at the bottom
let vignette = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        color(0, 0, 0, 0.25),
        color(0, 0, 0, 0.0)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    vignette,
    start: CGPoint(x: iconRect.midX, y: iconRect.minY),
    end:   CGPoint(x: iconRect.midX, y: iconRect.midY),
    options: []
)
ctx.restoreGState()

// --- Inner stroke for crispness ---
ctx.saveGState()
ctx.addPath(squircle)
ctx.setStrokeColor(color(1, 1, 1, 0.18))
ctx.setLineWidth(size * 0.004)
ctx.strokePath()
ctx.restoreGState()

// --- Lightning bolt ---
// Bolt designed in a 100x140 unit space, then mapped into the icon center.
let boltUnit = CGSize(width: 100, height: 140)
let boltPoints: [(CGFloat, CGFloat)] = [
    (58,   0),  // top right
    (10,  78),  // bottom-left of upper half
    (44,  78),
    (32, 140),  // bottom point
    (90,  56),
    (58,  56),
    (74,   0)
]

let boltScale = (iconRect.width * 0.46) / boltUnit.height
let boltSize = CGSize(width: boltUnit.width * boltScale, height: boltUnit.height * boltScale)
let boltOrigin = CGPoint(
    x: iconRect.midX - boltSize.width / 2,
    y: iconRect.midY - boltSize.height / 2
)

let boltPath = CGMutablePath()
for (i, p) in boltPoints.enumerated() {
    // CG y is flipped vs. unit (we treat y=0 as TOP), so invert.
    let pt = CGPoint(
        x: boltOrigin.x + p.0 * boltScale,
        y: boltOrigin.y + (boltUnit.height - p.1) * boltScale
    )
    if i == 0 { boltPath.move(to: pt) } else { boltPath.addLine(to: pt) }
}
boltPath.closeSubpath()

// Bolt drop shadow
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -size * 0.008),
    blur: size * 0.025,
    color: color(0, 0, 0, 0.35)
)
ctx.addPath(boltPath)
ctx.setFillColor(color(1, 1, 1, 1))
ctx.fillPath()
ctx.restoreGState()

// Bolt highlight gradient
ctx.saveGState()
ctx.addPath(boltPath)
ctx.clip()
let boltGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        color(1.00, 1.00, 1.00),
        color(0.92, 0.96, 1.00)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    boltGradient,
    start: CGPoint(x: boltOrigin.x, y: boltOrigin.y + boltSize.height),
    end:   CGPoint(x: boltOrigin.x + boltSize.width, y: boltOrigin.y),
    options: []
)
ctx.restoreGState()

// --- Save PNG ---
guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write("Failed to render image\n".data(using: .utf8)!)
    exit(1)
}
let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}

let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: outURL)
print("Wrote \(outPath) (\(Int(size))x\(Int(size)))")
