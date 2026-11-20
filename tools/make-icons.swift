#!/usr/bin/env swift
// Draws Lumen's icon candidates. Run with `swift tools/make-icons.swift <outdir>`.
//
// Kept as a script rather than committed PNGs so the design stays editable:
// re-run it after changing colours or geometry.

import AppKit
import Foundation

// MARK: - Paint helpers

/// macOS app icons sit on a "squircle", whose corners are fuller than a plain
/// rounded rect. This ratio approximates it closely at every size.
func squirclePath(in rect: NSRect, radiusRatio: CGFloat = 0.2237) -> NSBezierPath {
    NSBezierPath(roundedRect: rect,
                 xRadius: rect.width * radiusRatio,
                 yRadius: rect.width * radiusRatio)
}

func strokedCapsule(from start: CGPoint, to end: CGPoint, width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.move(to: start)
    path.line(to: end)
    return path
}

func strokedArc(center: CGPoint, radius: CGFloat,
                from startDegrees: CGFloat, to endDegrees: CGFloat,
                width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius,
                   startAngle: startDegrees, endAngle: endDegrees, clockwise: false)
    path.lineWidth = width
    path.lineCapStyle = .round
    return path
}

func linearGradient(_ colors: [NSColor], in path: NSBezierPath, angleDegrees: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let grad = CGGradient(colorsSpace: space,
                                colors: colors.map(\.cgColor) as CFArray,
                                locations: nil) else { return }
    ctx.saveGState()
    path.addClip()
    let b = path.bounds
    let radians = angleDegrees * .pi / 180
    let half = CGPoint(x: cos(radians) * b.height / 2, y: sin(radians) * b.height / 2)
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: b.midX - half.x, y: b.midY - half.y),
                           end: CGPoint(x: b.midX + half.x, y: b.midY + half.y),
                           options: [])
    ctx.restoreGState()
}

func radialGlow(center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let grad = CGGradient(colorsSpace: space,
                                colors: [color.withAlphaComponent(alpha).cgColor,
                                         color.withAlphaComponent(0).cgColor] as CFArray,
                                locations: [0, 1]) else { return }
    ctx.saveGState()
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

func fillSquircle(_ rect: NSRect, top: NSColor, bottom: NSColor, glow: (CGFloat, CGFloat)? = nil) {
    let squircle = squirclePath(in: rect)
    // Paint an opaque base first: a bare `fill()` without a colour would use
    // black and hide the gradient drawn over it.
    top.setFill()
    squircle.fill()
    linearGradient([top, bottom], in: squircle, angleDegrees: -90)
    if let (x, alpha) = glow {
        radialGlow(center: CGPoint(x: rect.width * x, y: rect.height * 0.66),
                   radius: rect.width * 0.66, color: .white, alpha: alpha)
    }
}

/// Glyphs get a soft drop shadow so they sit *above* the plate rather than
/// being printed flat onto it. Kept subtle: icon grids render small, and heavy
/// shadows turn into mud below 32 pt.
func withGlyphShadow(_ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 10
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - The mark
//
// A sun on the left, sound on the right. Both halves of the app in one glyph,
// and the silhouette stays readable down to 16 pt.

/// Geometry of the mark, shared by the sun and the sound waves so the two
/// cannot drift apart or overlap.
struct MarkGeometry {
    let center: CGPoint
    let discRadius: CGFloat
    let rayInner: CGFloat
    let rayOuter: CGFloat
    let rayWidth: CGFloat

    init(in rect: NSRect, centerShift: CGFloat = 0) {
        center = CGPoint(x: rect.midX + rect.width * centerShift, y: rect.midY)
        discRadius = rect.width * 0.205
        rayWidth = rect.width * 0.058
        rayInner = discRadius + rect.width * 0.068
        rayOuter = rayInner + rect.width * 0.088
    }
}

/// Sun disc plus rays. The rays facing right are omitted when sound waves take
/// that side, so the disc reads as the source the waves radiate from.
func drawSun(_ geo: MarkGeometry, color: NSColor,
             drawsRightRays: Bool, rayCount: Int = 6) {
    color.set()
    NSBezierPath(ovalIn: NSRect(x: geo.center.x - geo.discRadius,
                                y: geo.center.y - geo.discRadius,
                                width: geo.discRadius * 2,
                                height: geo.discRadius * 2)).fill()

    for i in 0..<rayCount {
        let angle = (CGFloat(i) / CGFloat(rayCount)) * 2 * .pi + .pi / CGFloat(rayCount)
        let degrees = (angle * 180 / .pi).truncatingRemainder(dividingBy: 360)
        // Screen y grows upwards, so 0° is due right; the waves occupy roughly
        // ±35°, and those rays would collide with them.
        if !drawsRightRays && (degrees < 35 || degrees > 325) { continue }
        let start = CGPoint(x: geo.center.x + cos(angle) * geo.rayInner,
                            y: geo.center.y + sin(angle) * geo.rayInner)
        let end = CGPoint(x: geo.center.x + cos(angle) * geo.rayOuter,
                          y: geo.center.y + sin(angle) * geo.rayOuter)
        strokedCapsule(from: start, to: end, width: geo.rayWidth).stroke()
    }
}

/// Concentric arcs radiating from the sun disc: the disc plays the part of a
/// speaker, so the whole mark stays a single coherent idea.
func drawSoundArcs(_ geo: MarkGeometry, color: NSColor) {
    color.set()
    let width = geo.rayWidth * 0.95
    // Radii measured from the disc edge, with a clear gap between the two arcs
    // so they read as separate waves rather than one thick band.
    for (index, radius) in [geo.discRadius * 1.60, geo.discRadius * 2.18].enumerated() {
        let span: CGFloat = index == 0 ? 36 : 32
        strokedArc(center: geo.center, radius: radius,
                   from: -span, to: span, width: width).stroke()
    }
}

/// Three rounded bars of rising height: an equaliser, the least ambiguous
/// "volume" signal at small sizes, and legible where arcs would look like Wi-Fi.
func drawSoundBars(_ geo: MarkGeometry, color: NSColor,
                   heights: [CGFloat] = [0.26, 0.38, 0.50]) {
    color.set()
    let width = geo.rayWidth * 1.45
    let gap = geo.rayWidth * 1.35
    let startX = geo.center.x + geo.rayOuter + width

    for (index, height) in heights.enumerated() {
        let x = startX + CGFloat(index) * (width + gap)
        let half = geo.discRadius * height * 2.4
        strokedCapsule(from: CGPoint(x: x, y: geo.center.y - half),
                       to: CGPoint(x: x, y: geo.center.y + half),
                       width: width).stroke()
    }
}

// MARK: - Candidates

struct Candidate {
    let name: String
    let caption: String
    let draw: (NSRect) -> Void
}

let candidates: [Candidate] = [
    Candidate(name: "warm", caption: "暖阳", draw: { rect in
        fillSquircle(rect,
                     top: NSColor(srgbRed: 1.00, green: 0.80, blue: 0.36, alpha: 1),
                     bottom: NSColor(srgbRed: 1.00, green: 0.46, blue: 0.25, alpha: 1),
                     glow: (0.5, 0.28))
        let glyph = rect.insetBy(dx: rect.width * 0.105, dy: rect.height * 0.105)
        let geo = MarkGeometry(in: glyph, centerShift: -0.085)
        withGlyphShadow {
            drawSun(geo, color: .white, drawsRightRays: false)
            drawSoundArcs(geo, color: .white)
        }
    }),

    Candidate(name: "warm-bars", caption: "暖阳 + 音量条", draw: { rect in
        fillSquircle(rect,
                     top: NSColor(srgbRed: 1.00, green: 0.80, blue: 0.36, alpha: 1),
                     bottom: NSColor(srgbRed: 1.00, green: 0.46, blue: 0.25, alpha: 1),
                     glow: (0.5, 0.28))
        let glyph = rect.insetBy(dx: rect.width * 0.105, dy: rect.height * 0.105)
        let geo = MarkGeometry(in: glyph, centerShift: -0.10)
        withGlyphShadow {
            drawSun(geo, color: .white, drawsRightRays: false)
            drawSoundBars(geo, color: .white)
        }
    }),

    Candidate(name: "night", caption: "夜光", draw: { rect in
        fillSquircle(rect,
                     top: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.34, alpha: 1),
                     bottom: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.16, alpha: 1))
        radialGlow(center: CGPoint(x: rect.width * 0.42, y: rect.height * 0.56),
                   radius: rect.width * 0.66,
                   color: NSColor(srgbRed: 1.0, green: 0.70, blue: 0.26, alpha: 1),
                   alpha: 0.50)
        let glyph = rect.insetBy(dx: rect.width * 0.105, dy: rect.height * 0.105)
        let geo = MarkGeometry(in: glyph, centerShift: -0.085)
        let cream = NSColor(srgbRed: 1.0, green: 0.93, blue: 0.78, alpha: 1)
        withGlyphShadow {
            drawSun(geo, color: cream, drawsRightRays: false)
            drawSoundArcs(geo, color: cream)
        }
    }),

    Candidate(name: "mono", caption: "素白", draw: { rect in
        fillSquircle(rect,
                     top: NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1),
                     bottom: NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1))
        let glyph = rect.insetBy(dx: rect.width * 0.105, dy: rect.height * 0.105)
        let geo = MarkGeometry(in: glyph, centerShift: -0.085)
        let ink = NSColor(srgbRed: 0.96, green: 0.50, blue: 0.16, alpha: 1)
        withGlyphShadow {
            drawSun(geo, color: ink, drawsRightRays: false)
            drawSoundArcs(geo, color: ink)
        }
    }),

    Candidate(name: "sun-only", caption: "只有太阳", draw: { rect in
        fillSquircle(rect,
                     top: NSColor(srgbRed: 1.00, green: 0.80, blue: 0.36, alpha: 1),
                     bottom: NSColor(srgbRed: 1.00, green: 0.46, blue: 0.25, alpha: 1),
                     glow: (0.5, 0.26))
        let glyph = rect.insetBy(dx: rect.width * 0.115, dy: rect.height * 0.115)
        let geo = MarkGeometry(in: glyph)
        withGlyphShadow {
            drawSun(geo, color: .white, drawsRightRays: true, rayCount: 12)
        }
    }),
]

// MARK: - Rendering

func render(size: CGFloat, draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    draw(NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

/// Menu bar template images must be pure black with alpha: macOS recolours them
/// for light/dark menu bars.
///
/// Laid out in absolute coordinates of a 128-unit canvas. At 18 pt the parts sit
/// close together, and percentage maths made the waves collide with the disc.
func menuBarGlyph() -> NSBitmapImageRep {
    render(size: 128) { rect in
        let unit = rect.width / 128
        NSColor.black.set()

        // Sun on the left; rays fan out away from the side the waves occupy.
        let center = CGPoint(x: 48 * unit, y: 64 * unit)
        let discRadius: CGFloat = 17 * unit
        NSBezierPath(ovalIn: NSRect(x: center.x - discRadius, y: center.y - discRadius,
                                    width: discRadius * 2, height: discRadius * 2)).fill()

        let rayWidth: CGFloat = 11 * unit
        let rayInner: CGFloat = discRadius + 7 * unit
        let rayOuter: CGFloat = rayInner + 10 * unit
        for degrees in [90.0, 135.0, 180.0, 225.0, 270.0] {
            let angle = CGFloat(degrees) * .pi / 180
            strokedCapsule(from: CGPoint(x: center.x + cos(angle) * rayInner,
                                         y: center.y + sin(angle) * rayInner),
                           to: CGPoint(x: center.x + cos(angle) * rayOuter,
                                       y: center.y + sin(angle) * rayOuter),
                           width: rayWidth).stroke()
        }

        // Two waves with a clear channel between them: at 18 pt a tighter gap
        // merges into one blob.
        for (radius, span) in [(CGFloat(42), CGFloat(34)), (CGFloat(61), CGFloat(30))] {
            strokedArc(center: center, radius: radius * unit,
                       from: -span, to: span,
                       width: 10 * unit).stroke()
        }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "./icons")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for candidate in candidates {
    writePNG(render(size: 512, draw: candidate.draw),
             to: outDir.appendingPathComponent("\(candidate.name).png"))
}
writePNG(menuBarGlyph(), to: outDir.appendingPathComponent("menubar.png"))

// Contact sheet on an opaque background, so gradient transparency cannot make
// the comparison look washed out.
let cell: CGFloat = 300
let labelHeight: CGFloat = 40
let sheetWidth = Int(cell) * candidates.count
let sheetHeight = Int(cell + labelHeight)
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil,
                             pixelsWide: sheetWidth, pixelsHigh: sheetHeight,
                             bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: CGFloat(sheetWidth), height: CGFloat(sheetHeight)).fill()
for (index, candidate) in candidates.enumerated() {
    let originX = CGFloat(index) * cell
    NSGraphicsContext.saveGraphicsState()
    candidate.draw(NSRect(x: originX + 30, y: labelHeight + 20,
                          width: cell - 60, height: cell - 60))
    NSGraphicsContext.restoreGraphicsState()

    let label = NSAttributedString(string: candidate.caption, attributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .medium),
        .foregroundColor: NSColor.black,
    ])
    let size = label.size()
    label.draw(at: NSPoint(x: originX + (cell - size.width) / 2, y: 12))
}
NSGraphicsContext.restoreGraphicsState()
writePNG(sheet, to: outDir.appendingPathComponent("candidates.png"))

// MARK: - .icns iconset
//
// `iconutil` wants every size present, and downscaling a single 512 master
// loses the crispness we tuned for small sizes. So each size is rendered
// natively instead.

let chosenName = args.count > 2 ? args[2] : "warm"
guard let chosen = candidates.first(where: { $0.name == chosenName }) else {
    print("unknown candidate: \(chosenName); available: \(candidates.map(\.name))")
    exit(1)
}

let iconSetDir = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconSetDir)
try? FileManager.default.createDirectory(at: iconSetDir, withIntermediateDirectories: true)

/// Every entry `iconutil` accepts, mapped to the pixel size to render.
let iconSetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for entry in iconSetEntries {
    writePNG(render(size: CGFloat(entry.pixels), draw: chosen.draw),
             to: iconSetDir.appendingPathComponent(entry.name))
}

print("wrote \(outDir.path)")
print("iconset: \(iconSetDir.path) (design: \(chosen.name))")
print("next: iconutil -c icns \"\(iconSetDir.path)\" -o \"\(outDir.path)/AppIcon.icns\"")
