#!/usr/bin/env swift
// Builds the icon comparison sheet: each candidate at the sizes macOS actually
// draws (256 for Spotlight/Finder, 128 in the Dock, 64/32/16 in lists and
// menu bar corners), so the choice can be judged at working size rather than
// only at 512.
//
// Run with `swift tools/preview-icons.swift <icons-dir> <output.png>`

import AppKit
import Foundation

let args = CommandLine.arguments
let iconsDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "./icons")
let outputPath = args.count > 2 ? args[2] : iconsDir.appendingPathComponent("preview.png").path

struct Entry {
    let file: String
    let name: String
}

let entries = [
    Entry(file: "warm.png", name: "A · 暖阳"),
    Entry(file: "warm-bars.png", name: "B · 暖阳 + 音量条"),
    Entry(file: "night.png", name: "C · 夜光"),
    Entry(file: "mono.png", name: "D · 素白"),
    Entry(file: "sun-only.png", name: "E · 只有太阳"),
]

let big: CGFloat = 220          // the "hero" render
let smallSizes: [CGFloat] = [64, 32, 16]
let columnWidth: CGFloat = 260
let columnGap: CGFloat = 24
let labelHeight: CGFloat = 46
let smallRowHeight: CGFloat = 80
let canvasHeight = labelHeight + big + 24 + smallRowHeight + 32
let canvasWidth = CGFloat(entries.count) * columnWidth + CGFloat(entries.count + 1) * columnGap

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(canvasWidth), pixelsHigh: Int(canvasHeight),
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// Opaque near-white page: a transparent background makes the gradients look
// washed out when the sheet is viewed over a dark window.
NSColor(srgbRed: 0.97, green: 0.97, blue: 0.975, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight).fill()

for (index, entry) in entries.enumerated() {
    let x = columnGap + CGFloat(index) * (columnWidth + columnGap)
    guard let image = NSImage(contentsOf: iconsDir.appendingPathComponent(entry.file)) else { continue }

    // Caption above each column keeps the sheet readable without a legend.
    let caption = NSAttributedString(string: entry.name, attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .medium),
        .foregroundColor: NSColor.black.withAlphaComponent(0.82),
    ])
    let captionSize = caption.size()
    caption.draw(at: NSPoint(x: x + (columnWidth - captionSize.width) / 2,
                             y: canvasHeight - labelHeight - captionSize.height / 2))

    let bigRect = NSRect(x: x + (columnWidth - big) / 2,
                         y: smallRowHeight + 24,
                         width: big, height: big)
    image.draw(in: bigRect)

    // Actual-size row. These are drawn at 1:1 against the sheet's pixel grid for
    // 64/32, and 16 gets the benefit of high-quality interpolation to show how it
    // resolves on a Retina menu bar.
    var smallX = x + 20
    for size in smallSizes {
        let rect = NSRect(x: smallX, y: (smallRowHeight - size) / 2, width: size, height: size)
        image.draw(in: rect)
        smallX += size + 14
    }
}

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
