import AppKit
import CoreGraphics
import Foundation

/// The menu bar's brand face: the app's own mark, drawn as a template line
/// drawing instead of a stock symbol. Idle wears the ring at rest, the two
/// plates settled; running wears the same ring with the stack pulsing, the
/// bright plate stepping from bottom to top and back to read as data
/// climbing it — see `MenuBarStatus.Glyph`. The attention face wears the
/// same ring with an exclamation mark standing where the stack sits — Time
/// Machine's own menu bar sign for a backup that needs the user — so the
/// mark never changes silhouette or size between faces.
///
/// Every face is a template image: the menu bar tints it with its own label
/// ink, whatever the bar's appearance. The attention face used to be a
/// baked bitmap with a blue dot, keyed on the status button's effective
/// appearance; applied at launch, before the button follows the bar, it
/// drew black ink on a dark bar and the mark vanished behind its dot. A
/// template has no ink to get wrong.
///
/// The plate stack, ring and head mirror the app icon's construction in
/// `Tools/GenerateAppIcon.swift`, so the tray and the Dock icon read as one
/// mark — keep the plate geometry in sync when the icon changes. The stroke
/// and arrowhead proportions are tuned for the 18pt status item and may
/// diverge from the generator's weights.
///
/// MainActor-isolated: the caches are AppKit bitmaps drawn once and consumed
/// only by menu bar and welcome-screen UI. CI's Swift flags the unisolated
/// statics as shared mutable non-Sendable state; the annotation turns that
/// real constraint into a compiler-enforced one.
@MainActor
enum MenuBarLogo {
    /// A standard status item's canvas.
    private static let canvasSize: CGFloat = 18
    /// The welcome screen's hero mark, same construction at display size.
    private static let heroCanvasSize: CGFloat = 96
    /// The generator's proportions are fractions of the full icon tile; the
    /// menu bar has no tile, so the glyph is drawn against a larger implied
    /// size, or the mark reads noticeably small next to neighboring status
    /// items. The tightest fit is not the ring (`radius + stroke / 2`) but
    /// the arrowhead's base corner: the ink stays inside the 18pt canvas with
    /// roughly 0.7–0.9pt of margin on every side.
    private static let impliedSize: CGFloat = 28

    /// At rest, both plates sit at their own settled alpha — no motion, just
    /// the stack. While running, the two plates take turns being the bright
    /// one — the brightness reads as climbing from the bottom plate to the
    /// top and back, in step with data moving up into the newest snapshot.
    private static let restingAlphas: [CGFloat] = [0.60, 1.0]
    /// Not a literal mirror pair: resting pins the top plate at 1.0, so a
    /// running frame topping out at 1.0 there would differ from rest in one
    /// plate only — and read as no change from idle. The top plate's bright
    /// value is capped at 0.80, short of resting's ceiling, so every running
    /// frame differs from rest in *both* plates.
    private static let runningAlphaFrames: [[CGFloat]] = [
        [1.0, 0.35],
        [0.35, 0.80],
    ]
    /// How long each running frame holds. Slow enough to read as a pulse in
    /// peripheral vision, not a flicker.
    static let frameInterval: TimeInterval = 0.6

    /// The exclamation mark's geometry, in fractions of the implied size as
    /// the stack's is, measured from the mark's centre (y up): a bar the
    /// stroke's width standing from a touch above the top plate's place to
    /// just below the centre, and its dot beneath, one stroke's gap between.
    /// It sits where the plates sit, so the ring, the head and the ink
    /// footprint are the idle face's. Read by the tests.
    static let exclamationBarTop: CGFloat = 0.170
    static let exclamationBarBottom: CGFloat = -0.030
    static let exclamationDotCenter: CGFloat = -0.135
    static let exclamationDotRadius: CGFloat = 0.040

    /// Which running frame is showing at a given moment. Pure so the cadence
    /// can be tested without a live timer or view.
    static func phase(at date: Date) -> Int {
        let step = Int((date.timeIntervalSinceReferenceDate / frameInterval).rounded(.down))
        return ((step % runningAlphaFrames.count) + runningAlphaFrames.count) % runningAlphaFrames.count
    }

    /// Built once, not per call: while a run is in flight the tray's pulse
    /// timer sets a running frame every `frameInterval`, so every face is
    /// cached and its accessor allocation-free.
    private static let restingImage: NSImage = makeImage { rect, context in
        draw(in: rect, into: context, content: .resting)
    }
    private static let runningImages: [NSImage] = runningAlphaFrames.indices.map { phase in
        makeImage { rect, context in
            draw(in: rect, into: context, content: .running(phase))
        }
    }
    private static let attentionImageCache: NSImage = makeImage { rect, context in
        draw(in: rect, into: context, content: .attention)
    }
    private static let heroImageCache: NSImage = makeImage(size: heroCanvasSize) { rect, context in
        draw(in: rect, into: context, content: .resting)
    }

    /// The ring at rest, the plate stack settled rather than pulsing.
    static func image() -> NSImage { restingImage }

    /// The attention face: the resting ring with an exclamation mark in the
    /// stack's place — a template like every face, on the same canvas, so
    /// the item neither changes width nor guesses the bar's ink.
    static var attentionImage: NSImage { attentionImageCache }

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
        case attention
        case running(Int)
    }

    /// Same ring-and-arrowhead construction as the icon generator, minus the
    /// tile, plus the snapshot stack, settled or pulsing, or the exclamation
    /// mark in its place — template rendering tints from the alpha channel
    /// alone, so a faded plate survives as gray. The construction fills the
    /// canvas proportionally, so the mark scales with it (the hero).
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
        case .attention:
            drawExclamation(into: context, center: center, s: s, stroke: stroke)
        case .running(let phase):
            drawStack(
                alphas: runningAlphaFrames[phase % runningAlphaFrames.count],
                into: context, center: center, s: s, stroke: stroke
            )
        }
    }

    /// The exclamation mark (`exclamationBarTop` and friends): the bar with
    /// the stroke's round ends, the dot below it, both solid ink.
    private static func drawExclamation(into context: CGContext, center: CGPoint, s: CGFloat, stroke: CGFloat) {
        context.saveGState()
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let bar = CGRect(
            x: center.x - stroke / 2,
            y: center.y + exclamationBarBottom * s,
            width: stroke,
            height: (exclamationBarTop - exclamationBarBottom) * s
        )
        context.addPath(CGPath(roundedRect: bar, cornerWidth: stroke / 2, cornerHeight: stroke / 2, transform: nil))
        context.fillPath()
        let dotRadius = exclamationDotRadius * s
        let dotCenter = CGPoint(x: center.x, y: center.y + exclamationDotCenter * s)
        context.fillEllipse(in: CGRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
        context.restoreGState()
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
