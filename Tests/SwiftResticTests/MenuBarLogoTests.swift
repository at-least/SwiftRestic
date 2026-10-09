import AppKit
import Foundation
import Testing

/// The running pulse's cadence, tested as the pure function it is rather than
/// through a live timer or view. MainActor like its subject: the enum's
/// caches are MainActor-isolated AppKit bitmaps.
@MainActor
@Suite("Menu bar logo")
struct MenuBarLogoTests {
    @Test("the running frame steps on a fixed cadence and wraps")
    func phaseSteps() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let firstPhase = MenuBarLogo.phase(at: start)

        // Inside one frame's hold time, the phase does not move.
        #expect(MenuBarLogo.phase(at: start.addingTimeInterval(MenuBarLogo.frameInterval * 0.5)) == firstPhase)

        // Past it, the frame has advanced — and with two frames, to the other one.
        #expect(MenuBarLogo.phase(at: start.addingTimeInterval(MenuBarLogo.frameInterval * 1.1)) != firstPhase)

        // A full two-frame cycle later, the pulse is back where it started.
        #expect(MenuBarLogo.phase(at: start.addingTimeInterval(MenuBarLogo.frameInterval * 2)) == firstPhase)
    }

    @Test("the resting mark and every running frame draw without crashing")
    func imageRenders() {
        #expect(MenuBarLogo.image().size.width > 0)
        #expect(MenuBarLogo.image(phase: 0).size.width > 0)
        #expect(MenuBarLogo.image(phase: 1).size.width > 0)
    }

    @Test("the Reduce Motion face is the held first frame, distinct from rest")
    func reducedMotionFace() {
        // Held: it is literally frame 0 of the pulse, not a new construction.
        #expect(MenuBarLogo.stillRunningImage === MenuBarLogo.image(phase: 0))
        // Distinct: a fallback of the resting mark would be indistinguishable
        // from idle on the only always-visible surface. TIFF bytes are the
        // cheapest honest comparison of two template bitmaps — the alphas
        // differ in both plates.
        #expect(MenuBarLogo.stillRunningImage.tiffRepresentation != MenuBarLogo.image().tiffRepresentation)
    }

    @Test("the attention face keeps the ring and stands an exclamation mark where the stack sits, as a template")
    func attentionFace() throws {
        let attention = MenuBarLogo.attentionImage
        // A template on the idle canvas: the bar tints it with its own ink,
        // and the item keeps its width between faces.
        #expect(attention.isTemplate, "the bar's ink, not a guess baked into a bitmap")
        #expect(attention.size.width == 18)
        #expect(attention.tiffRepresentation != MenuBarLogo.image().tiffRepresentation)

        // Pixel facts at 4x, coordinates in the 18pt canvas (y-up), the mark
        // centred at (9, 9) with s = 28 (`MenuBarLogo.impliedSize`).
        let rep = try render(attention, canvas: 18, scale: 4)
        let resting = try render(MenuBarLogo.image(), canvas: 18, scale: 4)
        func alpha(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> CGFloat {
            let color = try #require(rep.colorAt(x: Int((x * 4).rounded()), y: Int(((18 - y) * 4).rounded())))
                .usingColorSpace(.deviceRGB)
            return try #require(color).alphaComponent
        }
        let s: CGFloat = 28
        let barMiddle = 9 + (MenuBarLogo.exclamationBarTop + MenuBarLogo.exclamationBarBottom) / 2 * s
        try #expect(alpha(rep, x: 9, y: barMiddle) > 0.85, "the bar is solid ink")
        try #expect(alpha(rep, x: 9, y: 9 + MenuBarLogo.exclamationDotCenter * s) > 0.85, "the dot is solid ink")
        // Between bar and dot: clear. Where the plates' ends were: clear —
        // the stack is gone, where the resting face has ink there.
        try #expect(alpha(rep, x: 9, y: 9 - 0.08 * s) < 0.2, "a gap between bar and dot")
        try #expect(alpha(rep, x: 9 + 0.07 * s, y: 9 + 0.08 * s) < 0.2, "the top plate's end is clear")
        try #expect(alpha(rep, x: 9 + 0.07 * s, y: 9 - 0.08 * s) < 0.2, "the bottom plate's end is clear")
        try #expect(alpha(resting, x: 9 + 0.07 * s, y: 9 + 0.08 * s) > 0.85, "the control: rest has its top plate there")
        // The same ring: ink on its centreline at the lower right, and the
        // same ink footprint — the mark must not change size with its state.
        let ringRadius: CGFloat = 0.260 * s
        try #expect(alpha(rep, x: 9 + ringRadius * cos(.pi * 7 / 4), y: 9 + ringRadius * sin(.pi * 7 / 4)) > 0.85)
        let restingExtent = try inkExtent(resting, canvas: 18)
        let attentionExtent = try inkExtent(rep, canvas: 18)
        #expect(abs(attentionExtent.width - restingExtent.width) < 0.5)
        #expect(abs(attentionExtent.height - restingExtent.height) < 0.5)
    }

    /// The drawing's bounding box in points, from opaque pixels.
    private func inkExtent(_ rep: NSBitmapImageRep, canvas: CGFloat) throws -> CGRect {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                guard (color?.alphaComponent ?? 0) > 0.5 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        let scale = CGFloat(rep.pixelsWide) / canvas
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    @Test("every face renders, including the hero scale")
    func allFacesRender() {
        #expect(MenuBarLogo.attentionImage.size.width > 0)
        #expect(MenuBarLogo.heroImage.size.width == 96)
    }

    /// Renders a face for sampling or eyeballing. Pass `platter` to compose
    /// the alpha-only template ink onto an opaque colour for the PNG dumps;
    /// leave it nil for pixel tests, where the alpha channel itself is the
    /// fact under test.
    private func render(
        _ image: NSImage,
        canvas: CGFloat,
        scale: Int,
        platter: NSColor? = nil
    ) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas) * scale,
            pixelsHigh: Int(canvas) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = NSSize(width: canvas, height: canvas)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let platter {
            platter.setFill()
            NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()
        }
        image.draw(
            in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Visual-audit harness: set `SWIFTRESTIC_TRAY_FACE_DIR` to a directory
    /// and the four faces land there as 8x PNGs, composed on white. A no-op
    /// (passing test) when the variable is unset, so ordinary runs never
    /// write files.
    @Test("dump the tray faces as PNGs for visual audit")
    func dumpFaces() throws {
        guard let directory = ProcessInfo.processInfo.environment["SWIFTRESTIC_TRAY_FACE_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let faces: [(String, NSImage, CGFloat)] = [
            ("idle", MenuBarLogo.image(), 18),
            ("attention", MenuBarLogo.attentionImage, 18),
            ("running-0", MenuBarLogo.image(phase: 0), 18),
            ("running-1", MenuBarLogo.image(phase: 1), 18),
            ("hero", MenuBarLogo.heroImage, 96),
        ]
        for (name, image, canvas) in faces {
            let rep = try render(image, canvas: canvas, scale: 8, platter: .white)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "\(directory)/tray-\(name).png"))
        }
    }
}
