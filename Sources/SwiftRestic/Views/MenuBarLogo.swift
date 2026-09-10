import AppKit
import CoreGraphics

/// The menu bar's idle face: the app's own mark, drawn as a template line
/// drawing instead of a stock symbol.
///
/// The geometry mirrors the small-size (≤32 px) construction in
/// `Tools/GenerateAppIcon.swift` — ring radius 0.260, stroke 0.082, the head
/// hung at 36° to clear the top plate, and a two-plate snapshot stack with
/// the 0.60/1.0 alphas — so the tray wears the same mark the Dock icon does
/// at small sizes. Keep the two in sync when the icon changes.
enum MenuBarLogo {
    /// A standard status item's canvas.
    private static let canvasSize: CGFloat = 18
    /// The generator's proportions are fractions of the full icon tile, where
    /// the glyph fills about sixty percent. The menu bar has no tile, so the
    /// glyph is drawn against a larger implied size; the resulting ~1.6 pt
    /// stroke sits next to the SF Symbols of the running and problem faces
    /// without looking heavier than them.
    private static let impliedSize: CGFloat = 20

    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: rect, into: context)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Same construction as the icon generator, minus the tile: the arc, the
    /// filled head, and the plates in black — template rendering tints from
    /// the alpha channel alone, so the faded bottom plate survives as gray.
    private static func draw(in rect: CGRect, into context: CGContext) {
        let s = impliedSize * rect.width / canvasSize
        let stroke = s * 0.082
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ink = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

        // Circular restore arrow: opening on the left, sweeping
        // counterclockwise from the tail below it to the head above.
        let ringRadius = s * 0.260
        let startAngle = .pi + radians(40)
        let endAngle = .pi - radians(36)
        context.saveGState()
        context.setStrokeColor(ink)
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.addArc(
            center: center,
            radius: ringRadius,
            startAngle: startAngle,
            endAngle: endAngle + 2 * .pi,
            clockwise: false
        )
        context.strokePath()

        // Filled, rounded arrowhead pointing straight down into the opening,
        // its base centered on the end of the arc to cover the round cap.
        let arcEnd = CGPoint(
            x: center.x + cos(endAngle) * ringRadius,
            y: center.y + sin(endAngle) * ringRadius
        )
        context.translateBy(x: arcEnd.x, y: arcEnd.y)
        let outline = stroke * 0.5
        let joinInset = outline / 2
        let headLength = stroke * 2.3 - joinInset
        let headHalfBase = stroke * 1.45 - joinInset
        context.setLineWidth(outline)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: -headHalfBase, y: -joinInset))
        context.addLine(to: CGPoint(x: headHalfBase, y: -joinInset))
        context.addLine(to: CGPoint(x: 0, y: -headLength))
        context.closePath()
        context.setFillColor(ink)
        context.drawPath(using: .fillStroke)
        context.restoreGState()

        // Two-plate snapshot stack, the newest on top and fully opaque.
        let plateWidth = s * 0.190
        let spacing = s * 0.160
        let alphas: [CGFloat] = [0.60, 1.0]
        let stackOffset = CGFloat(alphas.count - 1) * spacing / 2
        for (index, alpha) in alphas.enumerated() {
            let y = center.y - stackOffset + CGFloat(index) * spacing
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha))
            let rect = CGRect(
                x: center.x - plateWidth / 2,
                y: y - stroke / 2,
                width: plateWidth,
                height: stroke
            )
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: stroke / 2,
                cornerHeight: stroke / 2,
                transform: nil
            ))
            context.fillPath()
        }
    }

    private static func radians(_ degrees: CGFloat) -> CGFloat {
        degrees * .pi / 180
    }
}
