#!/usr/bin/env swift
//
// Draws the SwiftRestic app icon and writes every size the asset catalog needs.
//
//   swift Tools/GenerateAppIcon.swift
//
// The artwork is vector, so each size is rendered natively rather than
// downscaled from one master — strokes stay crisp at 16pt.
//
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry helpers

/// Apple's icon shape is a continuous-corner squircle, which `CGPath`'s circular
/// `roundedRect` does not reproduce. Sample the superellipse directly.
func squirclePath(in rect: CGRect, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width / 2)
    let b = Double(rect.height / 2)
    let cx = Double(rect.midX)
    let cy = Double(rect.midY)
    let steps = 720

    for step in 0 ... steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        // |x/a|^n + |y/b|^n = 1 in parametric form.
        let x = cx + a * pow(abs(cosT), 2 / exponent) * (cosT < 0 ? -1 : 1)
        let y = cy + b * pow(abs(sinT), 2 / exponent) * (sinT < 0 ? -1 : 1)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

/// A rounded horizontal plate — one "snapshot" in the stack.
func platePath(center: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
    let rect = CGRect(
        x: center.x - width / 2,
        y: center.y - height / 2,
        width: width,
        height: height
    )
    return CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

// MARK: - Drawing

/// Glyph proportions, as fractions of the canvas.
///
/// The whole glyph is drawn with one stroke weight: the ring and the height of
/// each plate are both `stroke`, with round caps everywhere, which is what makes
/// the glyph read like an SF Symbol rather than an illustration. The ring is
/// built the way Apple builds `arrow.circlepath` (the Time Machine glyph): the
/// opening sits on the left, the arc sweeps counterclockwise from the tail at
/// the lower end of the opening, and a filled, rounded triangular head at the
/// upper end points straight down into the opening, back toward the tail. The
/// head is axis-aligned rather than tangent to the arc; that is what keeps it
/// reading as an arrow instead of a hook flying off the ring.
///
/// Small sizes get a deliberately coarser glyph. At 16pt the three-plate stack
/// leaves gaps under half a pixel wide and collapses into a smudge, so those
/// sizes drop to two plates and a heavier stroke. The choice is keyed on pixel
/// count rather than point size, so 16pt@2x and 32pt@1x — both 32 pixels —
/// always render identically.
struct Proportions {
    var ringRadius: CGFloat
    var stroke: CGFloat
    /// Where the stroke ends and the head sits, in degrees above the left
    /// horizontal, and where the stroke starts, in degrees below it. The opening
    /// is deliberately asymmetric: the head hangs a little higher than the tail.
    var headAngle: CGFloat
    var tailAngle: CGFloat
    var plateWidth: CGFloat
    var plateSpacing: CGFloat
    /// Bottom plate first; the last one is the newest snapshot and fully opaque.
    var plateAlphas: [CGFloat]
    var drawsShadow: Bool

    static func forPixelSize(_ pixels: Int) -> Proportions {
        if pixels <= 32 {
            Proportions(
                // The head hangs higher here so its inner corner clears the top
                // plate; at this size the two would otherwise fuse into a blob.
                ringRadius: 0.260, stroke: 0.082, headAngle: 36, tailAngle: 40,
                plateWidth: 0.190, plateSpacing: 0.160,
                plateAlphas: [0.60, 1.0],
                // A blurred shadow only muddies the edge at this size.
                drawsShadow: false
            )
        } else {
            Proportions(
                ringRadius: 0.252, stroke: 0.051, headAngle: 30, tailAngle: 36,
                plateWidth: 0.191, plateSpacing: 0.098,
                plateAlphas: [0.40, 0.66, 1.0],
                drawsShadow: true
            )
        }
    }
}

func drawIcon(size: CGFloat, into context: CGContext) {
    let s = size
    let proportions = Proportions.forPixelSize(Int(size))
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // The glyph sits inside the squircle, which is inset from the full canvas the
    // way macOS icons are (824 of 1024).
    let inset = s * 100 / 1024
    let shape = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = squirclePath(in: shape)

    // Drop shadow beneath the tile.
    context.saveGState()
    if proportions.drawsShadow {
        context.setShadow(
            offset: CGSize(width: 0, height: -s * 0.010),
            blur: s * 0.028,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.26)
        )
    }
    context.addPath(path)
    context.setFillColor(color(0x0F7488))
    context.fillPath()
    context.restoreGState()

    // Background: one restrained two-stop teal gradient, lighter at the top. No
    // gloss band and no diagonal — the depth comes from the gradient alone.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x48C9BD), color(0x0F7488)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: shape.midX, y: shape.maxY),
        end: CGPoint(x: shape.midX, y: shape.minY),
        options: []
    )
    context.restoreGState()

    let center = CGPoint(x: shape.midX, y: shape.midY)
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let stroke = s * proportions.stroke

    // Circular restore arrow sweeping counterclockwise around the stack — the
    // same direction Time Machine's arrow turns, back through time.
    let ringRadius = s * proportions.ringRadius
    context.saveGState()
    context.setStrokeColor(white)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    // The opening is on the left. Going counterclockwise the stroke starts at
    // the lower edge of the opening and ends at its upper edge, so the arrowhead
    // belongs at `headAngle` — the end of the stroke, not its tail.
    let tailAngle = .pi + proportions.tailAngle * .pi / 180
    let headAngle = .pi - proportions.headAngle * .pi / 180
    context.addArc(
        center: center,
        radius: ringRadius,
        startAngle: tailAngle,
        endAngle: headAngle + 2 * .pi,
        clockwise: false
    )
    context.strokePath()

    // Filled arrowhead pointing straight down: 2.3 strokes long and 2.9 across
    // the base, with the base's midpoint on the end of the arc so it covers the
    // arc's round cap. The outline is stroked with round joins to round the
    // corners the same way the rest of the glyph is rounded; the path is inset
    // by half that outline so the finished shape lands on those measurements.
    let arcEnd = CGPoint(
        x: center.x + cos(headAngle) * ringRadius,
        y: center.y + sin(headAngle) * ringRadius
    )
    context.saveGState()
    context.translateBy(x: arcEnd.x, y: arcEnd.y)
    let edge = stroke * 0.5
    let headLength = stroke * 2.3 - edge / 2
    let headHalfBase = stroke * 1.45 - edge / 2
    context.setLineWidth(edge)
    context.move(to: CGPoint(x: -headHalfBase, y: -edge / 2))
    context.addLine(to: CGPoint(x: headHalfBase, y: -edge / 2))
    context.addLine(to: CGPoint(x: 0, y: -headLength))
    context.closePath()
    context.setFillColor(white)
    context.drawPath(using: .fillStroke)
    context.restoreGState()
    context.restoreGState()

    // Snapshot stack. Index 0 is drawn lowest (Core Graphics is y-up), so the
    // ascending alphas put the newest, brightest plate on top.
    let plateWidth = s * proportions.plateWidth
    let spacing = s * proportions.plateSpacing
    let alphas = proportions.plateAlphas
    let stackOffset = CGFloat(alphas.count - 1) * spacing / 2
    for (index, alpha) in alphas.enumerated() {
        let y = center.y - stackOffset + CGFloat(index) * spacing
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        context.addPath(platePath(
            center: CGPoint(x: center.x, y: y),
            width: plateWidth,
            height: stroke
        ))
        context.fillPath()
    }
}

// MARK: - Output

func renderPNG(size: Int, to url: URL) throws {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    drawIcon(size: CGFloat(size), into: context)

    guard let image = context.makeImage() else {
        throw NSError(domain: "icon", code: 1)
    }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "icon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "icon", code: 3)
    }
}

/// (point size, scale) pairs macOS asks for.
let variants: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let arguments = CommandLine.arguments
let outputDirectory = URL(
    fileURLWithPath: arguments.count > 1
        ? arguments[1]
        : "Sources/SwiftRestic/Assets.xcassets/AppIcon.appiconset"
)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

var images: [[String: String]] = []
for variant in variants {
    let pixels = variant.point * variant.scale
    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let filename = "icon_\(variant.point)x\(variant.point)\(suffix).png"
    try renderPNG(size: pixels, to: outputDirectory.appendingPathComponent(filename))
    images.append([
        "size": "\(variant.point)x\(variant.point)",
        "idiom": "mac",
        "filename": filename,
        "scale": "\(variant.scale)x",
    ])
    print("wrote \(filename) (\(pixels)px)")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "xcode"],
]
let data = try JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys]
)
try data.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
