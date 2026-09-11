import AppKit
import CoreGraphics
import Foundation

/// The menu bar's brand face: the app's own mark, drawn as a template line
/// drawing instead of a stock symbol. Idle wears the ring at rest, the two
/// plates settled; running wears the same ring with the stack pulsing, the
/// bright plate stepping from bottom to top and back to read as data
/// climbing it — see `MenuBarStatus.Glyph`. Both intervention states wear
/// the resting mark with one small companion dot at the ring's lower-right —
/// the unread-badge grammar Mail's Dock icon follows: the mark never
/// changes silhouette, the dot alone says "open me".
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
    /// The badged face's canvas: one point of extra margin on every side so
    /// the dot's transparent halo stays inside the bitmap. The construction
    /// is drawn at the same absolute size (`impliedSize` is resolved against
    /// this canvas), so the mark itself never changes size between faces —
    /// only the item's width moves, which the old symbol faces did too.
    private static let badgedCanvasSize: CGFloat = 20
    /// The welcome screen's hero mark, same construction at display size.
    private static let heroCanvasSize: CGFloat = 96
    /// The generator's proportions are fractions of the full icon tile, where
    /// the glyph fills about sixty percent. The menu bar has no tile, so the
    /// glyph is drawn against a larger implied size — measured next to a
    /// neighboring status item's icon, the mark read noticeably smaller until
    /// pushed this far. The tightest fit is not the ring (`radius + stroke /
    /// 2`, `0.294 * s`) but the arrowhead's base corner: the ink stays inside
    /// the 18pt canvas with roughly 0.7–0.9pt of margin on every side.
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

    /// Template ink: alpha alone carries the drawing.
    private static let ink = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

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
    private static let badgedImageCache: NSImage = makeImage(size: badgedCanvasSize) { rect, context in
        draw(in: rect, into: context, content: .badged, scaleBasis: badgedCanvasSize)
    }
    private static let heroImageCache: NSImage = makeImage(size: heroCanvasSize) { rect, context in
        draw(in: rect, into: context, content: .resting)
    }

    /// The ring at rest, the plate stack settled rather than pulsing.
    static func image() -> NSImage { restingImage }

    /// The attention face: the resting mark plus the companion dot.
    static var badgedImage: NSImage { badgedImageCache }

    /// The welcome screen's brand mark — the app's own construction at hero
    /// scale, not a borrowed SF Symbol.
    static var heroImage: NSImage { heroImageCache }

    /// A running frame: the ring with the snapshot stack pulsing.
    static func image(phase: Int) -> NSImage {
        runningImages[((phase % runningImages.count) + runningImages.count) % runningImages.count]
    }

    /// The Reduce Motion face: the first running frame, held still. Nothing
    /// animates, but unlike the resting mark it differs from idle in both
    /// plates — a fallback that erased the running cue would leave these users
    /// no way to tell "backing up" from "idle" without clicking.
    static var stillRunningImage: NSImage { runningImages[0] }

    private static func makeImage(
        size: CGFloat = canvasSize,
        _ draw: @escaping (CGRect, CGContext) -> Void
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(rect, context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private enum Content {
        case resting
        case badged
        case running(Int)
    }

    /// Same ring-and-arrowhead construction as the icon generator, minus the
    /// tile, plus the snapshot stack, settled or pulsing — template
    /// rendering tints from the alpha channel alone, so a faded plate
    /// survives as gray.
    ///
    /// `scaleBasis` is the canvas the construction proportionally fills. The
    /// full-bleed faces (resting, running, hero) take the default, so the
    /// mark scales with its canvas as it always has. The badged face passes
    /// its own canvas instead: one-to-one with `impliedSize`, the mark keeps
    /// the idle construction's absolute size and the wider canvas buys real
    /// halo margin — the tray glyph must never change size with its state.
    private static func draw(
        in rect: CGRect,
        into context: CGContext,
        content: Content,
        scaleBasis: CGFloat = canvasSize
    ) {
        let s = impliedSize * rect.width / scaleBasis
        let stroke = s * 0.068
        let center = CGPoint(x: rect.midX, y: rect.midY)

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
        case .badged:
            drawStack(alphas: restingAlphas, into: context, center: center, s: s, stroke: stroke)
            drawAttentionDot(into: context, center: center, s: s)
        case .running(let phase):
            drawStack(
                alphas: runningAlphaFrames[phase % runningAlphaFrames.count],
                into: context, center: center, s: s, stroke: stroke
            )
        }
    }

    /// The companion dot that turns the resting mark into the attention face:
    /// one small filled circle pinned on the ring at its lower-right, away
    /// from the arrowhead's upper-left. Template rendering tints from alpha
    /// alone, so the halo around the dot is knocked out to *transparent* —
    /// a drawn light-coloured ring would tint as ink and read as a second
    /// stroke — which leaves a real gap between dot and ring on any menu bar.
    private static func drawAttentionDot(into context: CGContext, center: CGPoint, s: CGFloat) {
        let ringRadius = s * 0.260
        let dotRadius = s * 0.064
        let haloRadius = s * 0.093
        let angle = CGFloat.pi * 7 / 4
        let dotCenter = CGPoint(
            x: center.x + cos(angle) * ringRadius,
            y: center.y + sin(angle) * ringRadius
        )
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: ellipse(at: dotCenter, radius: haloRadius))
        context.setBlendMode(.normal)
        context.setFillColor(ink)
        context.fillEllipse(in: ellipse(at: dotCenter, radius: dotRadius))
        context.restoreGState()
    }

    private static func ellipse(at center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
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
