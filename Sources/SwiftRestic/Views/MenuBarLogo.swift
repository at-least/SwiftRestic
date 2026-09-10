import AppKit
import CoreGraphics
import Foundation

/// The menu bar's brand face: the app's own mark, drawn as a template line
/// drawing instead of a stock symbol. Idle wears the ring at rest, the two
/// plates settled; running wears the same ring with the stack pulsing, the
/// bright plate stepping from bottom to top and back to read as data
/// climbing it — see `MenuBarStatus.Glyph`. Unconfigured and problem wear a
/// bare SF Symbol instead, not this mark — a silhouette change reads faster
/// than a mark with a badge stuffed inside it.
///
/// The ring radius (0.260) and plate geometry mirror the small-size (≤32 px)
/// construction in `Tools/GenerateAppIcon.swift`, and the head hangs at the
/// same 36° to clear the top plate — so the tray wears the same silhouette
/// the Dock icon does at small sizes. The stroke (0.068, vs the generator's
/// 0.082) and arrowhead proportions are tuned separately for this canvas: an
/// 18pt status item reads a tighter arrowhead better than the icon's own
/// weight does. Keep the ring radius and plate geometry in sync when the
/// icon changes; the stroke and arrowhead are allowed to diverge on purpose.
enum MenuBarLogo {
    /// A standard status item's canvas.
    private static let canvasSize: CGFloat = 18
    /// The generator's proportions are fractions of the full icon tile, where
    /// the glyph fills about sixty percent. The menu bar has no tile, so the
    /// glyph is drawn against a larger implied size, overflowing the canvas
    /// on purpose — measured next to a neighboring status item's icon, the
    /// mark read noticeably smaller until pushed this far. The ring's
    /// outer edge (`radius + stroke / 2`, `0.294 * s`) still lands inside
    /// the canvas half-width of 9 at this size.
    private static let impliedSize: CGFloat = 28

    /// At rest, both plates sit at their own settled alpha — no motion, just
    /// the stack. While running, the two plates take turns being the bright
    /// one — the brightness reads as climbing from the bottom plate to the
    /// top and back, in step with data moving up into the newest snapshot.
    private static let restingAlphas: [CGFloat] = [0.60, 1.0]
    /// Not a literal mirror pair: resting already pins the top plate at 1.0,
    /// so a running frame that also tops out at 1.0 there is pixel-identical
    /// to rest on that plate — measured, this made one of the two running
    /// frames read as no change from idle at all. The top plate's bright
    /// value is capped at 0.80 instead, short of resting's ceiling, so every
    /// running frame differs from rest in *both* plates, not just one.
    private static let runningAlphaFrames: [[CGFloat]] = [
        [1.0, 0.35],
        [0.35, 0.80],
    ]
    /// How long each running frame holds. Slow enough to read as a pulse in
    /// peripheral vision, not a flicker.
    static let frameInterval: TimeInterval = 0.6

    /// Which running frame is showing at a given moment. Pure so the cadence
    /// can be tested without a live timer or view.
    static func phase(at date: Date) -> Int {
        let step = Int((date.timeIntervalSinceReferenceDate / frameInterval).rounded(.down))
        return ((step % runningAlphaFrames.count) + runningAlphaFrames.count) % runningAlphaFrames.count
    }

    /// Built once, not per call: the status item's label re-evaluates this on
    /// every `TimelineView` tick while a run is in flight, and a fresh
    /// `NSImage` on every 0.6s tick was the actual pre-fix behavior — this
    /// restores the pre-animation caching for all three faces.
    private static let restingImage: NSImage = makeImage { rect, context in
        draw(in: rect, into: context, content: .resting)
    }
    private static let runningImages: [NSImage] = runningAlphaFrames.indices.map { phase in
        makeImage { rect, context in
            draw(in: rect, into: context, content: .running(phase))
        }
    }

    /// The ring at rest, the plate stack settled rather than pulsing.
    static func image() -> NSImage { restingImage }

    /// A running frame: the ring with the snapshot stack pulsing.
    static func image(phase: Int) -> NSImage {
        runningImages[((phase % runningImages.count) + runningImages.count) % runningImages.count]
    }

    private static func makeImage(_ draw: @escaping (CGRect, CGContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(rect, context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private enum Content {
        case resting
        case running(Int)
    }

    /// Same ring-and-arrowhead construction as the icon generator, minus the
    /// tile, plus the snapshot stack, settled or pulsing — template
    /// rendering tints from the alpha channel alone, so a faded plate
    /// survives as gray.
    private static func draw(in rect: CGRect, into context: CGContext, content: Content) {
        let s = impliedSize * rect.width / canvasSize
        let stroke = s * 0.068
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ink = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

        // Circular restore arrow: opening on the left, sweeping
        // counterclockwise from the tail below it to the head above.
        let ringRadius = s * 0.260
        let startAngle = CGFloat.pi + radians(40)
        let endAngle = CGFloat.pi - radians(36)
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
        let headLength = stroke * 1.9 - joinInset
        let headHalfBase = stroke * 1.15 - joinInset
        context.setLineWidth(outline)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: -headHalfBase, y: -joinInset))
        context.addLine(to: CGPoint(x: headHalfBase, y: -joinInset))
        context.addLine(to: CGPoint(x: 0, y: -headLength))
        context.closePath()
        context.setFillColor(ink)
        context.drawPath(using: .fillStroke)
        context.restoreGState()

        switch content {
        case .resting:
            drawStack(alphas: restingAlphas, into: context, center: center, s: s, stroke: stroke)
        case .running(let phase):
            drawStack(
                alphas: runningAlphaFrames[phase % runningAlphaFrames.count],
                into: context, center: center, s: s, stroke: stroke
            )
        }
    }

    private static func drawStack(
        alphas: [CGFloat], into context: CGContext, center: CGPoint, s: CGFloat, stroke: CGFloat
    ) {
        let plateWidth = s * 0.190
        let spacing = s * 0.160
        let stackOffset = CGFloat(alphas.count - 1) * spacing / 2
        for (index, alpha) in alphas.enumerated() {
            let y = center.y - stackOffset + CGFloat(index) * spacing
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha))
            let plateRect = CGRect(
                x: center.x - plateWidth / 2,
                y: y - stroke / 2,
                width: plateWidth,
                height: stroke
            )
            context.addPath(CGPath(
                roundedRect: plateRect,
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
