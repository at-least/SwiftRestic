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
/// Small sizes get a deliberately coarser glyph. At 16pt the three-plate stack
/// leaves gaps under half a pixel wide and collapses into a smudge, so those
/// sizes drop to two thicker plates and a heavier ring. The choice is keyed on
/// pixel count rather than point size, so 16pt@2x and 32pt@1x — both 32 pixels —
/// always render identically.
struct Proportions {
    var ringRadius: CGFloat
    var ringWidth: CGFloat
    var plateWidth: CGFloat
    var plateHeight: CGFloat
    var plateSpacing: CGFloat
    /// Bottom plate first; the last one is the newest snapshot and fully opaque.
    var plateAlphas: [CGFloat]
    var drawsShadow: Bool

    static func forPixelSize(_ pixels: Int) -> Proportions {
        if pixels <= 32 {
            Proportions(
                ringRadius: 0.292, ringWidth: 0.092,
                plateWidth: 0.286, plateHeight: 0.092, plateSpacing: 0.156,
                plateAlphas: [0.62, 1.0],
                // A blurred shadow only muddies the edge at this size.
                drawsShadow: false
            )
        } else {
            Proportions(
                ringRadius: 0.278, ringWidth: 0.070,
                plateWidth: 0.300, plateHeight: 0.062, plateSpacing: 0.112,
                plateAlphas: [0.50, 0.74, 1.0],
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
            offset: CGSize(width: 0, height: -s * 0.012),
            blur: s * 0.03,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
        )
    }
    context.addPath(path)
    context.setFillColor(color(0x2B3AA0))
    context.fillPath()
    context.restoreGState()

    // Background gradient: light blue at the top-left, deep navy at the bottom.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x5C8BFF), color(0x3B4FD8), color(0x1E2160)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: shape.minX, y: shape.maxY),
        end: CGPoint(x: shape.maxX, y: shape.minY),
        options: []
    )

    // Soft highlight along the top edge, which is what stops a flat gradient from
    // looking like a sticker at large sizes.
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        highlight,
        start: CGPoint(x: shape.midX, y: shape.maxY),
        end: CGPoint(x: shape.midX, y: shape.midY),
        options: []
    )
    context.restoreGState()

    let center = CGPoint(x: shape.midX, y: shape.midY)
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    // Circular restore arrow sweeping around the stack.
    let ringRadius = s * proportions.ringRadius
    let ringWidth = s * proportions.ringWidth
    context.saveGState()
    context.setStrokeColor(white)
    context.setLineWidth(ringWidth)
    context.setLineCap(.butt)
    // The arc runs counterclockwise from `gapEnd` round to `gapStart`, so the
    // arrowhead belongs at `gapStart` — the end of the stroke, not its tail.
    let gapStart: CGFloat = 74 * .pi / 180
    let gapEnd: CGFloat = 116 * .pi / 180
    context.addArc(
        center: center,
        radius: ringRadius,
        startAngle: gapEnd,
        endAngle: gapStart + 2 * .pi,
        clockwise: false
    )
    context.strokePath()

    // The head's base sits well behind the arc's end, so the stroke needs no
    // overshoot — any would show as a step along the arrowhead's outer edge.
    let headAngle = gapStart
    let headCenter = CGPoint(
        x: center.x + cos(headAngle) * ringRadius,
        y: center.y + sin(headAngle) * ringRadius
    )
    let headLength = ringWidth * 1.16
    let headHalfWidth = ringWidth * 0.94
    context.saveGState()
    context.translateBy(x: headCenter.x, y: headCenter.y)
    // Local +x points along the direction of travel: the tangent at `headAngle`
    // for a counterclockwise sweep is that angle plus a quarter turn.
    context.rotate(by: headAngle + .pi / 2)
    context.move(to: CGPoint(x: headLength, y: 0))
    context.addLine(to: CGPoint(x: -headLength * 0.78, y: headHalfWidth))
    context.addLine(to: CGPoint(x: -headLength * 0.78, y: -headHalfWidth))
    context.closePath()
    context.setFillColor(white)
    context.fillPath()
    context.restoreGState()
    context.restoreGState()

    // Snapshot stack. Index 0 is drawn lowest (Core Graphics is y-up), so the
    // ascending alphas put the newest, brightest plate on top.
    let plateWidth = s * proportions.plateWidth
    let plateHeight = s * proportions.plateHeight
    let spacing = s * proportions.plateSpacing
    let alphas = proportions.plateAlphas
    let stackOffset = CGFloat(alphas.count - 1) * spacing / 2
    for (index, alpha) in alphas.enumerated() {
        let y = center.y - stackOffset + CGFloat(index) * spacing
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        context.addPath(platePath(
            center: CGPoint(x: center.x, y: y),
            width: plateWidth,
            height: plateHeight
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
