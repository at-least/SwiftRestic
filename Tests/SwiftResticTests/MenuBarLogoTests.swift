import AppKit
import Foundation
import Testing

/// The running pulse's cadence, tested as the pure function it is rather than
/// through a live timer or view.
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
        // Distinct: the old fallback handed Reduce Motion users the resting
        // mark, indistinguishable from idle on the only always-visible surface.
        // TIFF bytes are the cheapest honest comparison of two template
        // bitmaps — the alphas differ in both plates.
        #expect(MenuBarLogo.stillRunningImage.tiffRepresentation != MenuBarLogo.image().tiffRepresentation)
    }

    @Test("the attention face keeps the mark and adds a haloed dot on the ring")
    func badgedFace() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let badged = MenuBarLogo.badgedImage(for: light)
        // Same identity, one companion mark: the TIFF differs from rest, and
        // the badged canvas is one point wider on every side for the halo.
        #expect(badged.tiffRepresentation != MenuBarLogo.image().tiffRepresentation)
        #expect(badged.size.width == 20)
        #expect(!badged.isTemplate, "the blue dot must be baked in, so this face cannot be template")

        // Pixel facts at 4x, coordinates in the 20pt canvas (y-up). The dot
        // sits on the ring at its lower-right; the halo between dot and ring
        // must be truly transparent, and the ring must survive right next
        // door — a halo that tinted as ink would read as a second stroke.
        let rep = try render(badged, canvas: 20, scale: 4)
        func alpha(x: CGFloat, y: CGFloat) throws -> CGFloat {
            let pixel = NSPoint(
                x: (x * 4).rounded(),
                y: ((20 - y) * 4).rounded() // bitmap rows run top-down
            )
            let color = try #require(rep.colorAt(x: Int(pixel.x), y: Int(pixel.y)))
                .usingColorSpace(.deviceRGB)
            return try #require(color).alphaComponent
        }

        // Geometry from MenuBarLogo's construction (scale basis = the 20pt
        // canvas, so s = 28 exactly): ring radius 0.260 * 28, dot radius
        // 0.064 * 28, halo 0.093 * 28, dot centered at 7π/4 on the ring.
        let ringRadius: CGFloat = 0.260 * 28
        let dotCenter = CGVector(dx: 10 + ringRadius * cos(.pi * 7 / 4), dy: 10 + ringRadius * sin(.pi * 7 / 4))
        try #expect(alpha(x: dotCenter.dx, y: dotCenter.dy) > 0.85, "the dot itself is solid ink")
        // The dot is baked in systemBlue, not the mark's ink: blue dominates.
        let dotColor = try #require(rep.colorAt(
            x: Int((dotCenter.dx * 4).rounded()),
            y: Int(((20 - dotCenter.dy) * 4).rounded())
        )?.usingColorSpace(.deviceRGB))
        #expect(dotColor.blueComponent > dotColor.redComponent + 0.2, "the light face's dot is blue")
        // On the ring's centerline 17° away: inside the halo, outside the dot.
        let gap = CGVector(dx: 10 + ringRadius * cos(.pi * 7 / 4 + 0.30), dy: 10 + ringRadius * sin(.pi * 7 / 4 + 0.30))
        try #expect(alpha(x: gap.dx, y: gap.dy) < 0.2, "the halo separates dot from ring with real transparency")
        // On the ring's centerline 33° away: past the halo, ink must survive.
        let survivor = CGVector(dx: 10 + ringRadius * cos(.pi * 7 / 4 + 0.58), dy: 10 + ringRadius * sin(.pi * 7 / 4 + 0.58))
        try #expect(alpha(x: survivor.dx, y: survivor.dy) > 0.85, "the ring survives beside the dot")
        // The light face's ink is black — routing the dark ink here would
        // still pass the alpha check above, so pin the colour itself.
        let inkColor = try #require(rep.colorAt(
            x: Int((survivor.dx * 4).rounded()),
            y: Int(((20 - survivor.dy) * 4).rounded())
        )?.usingColorSpace(.deviceRGB))
        #expect(inkColor.redComponent < 0.15, "the light face's mark draws in black ink")

        // The mark itself must not change size with its state: the badged
        // construction is drawn one-to-one with the idle construction, so
        // their ink footprints match (a scale slip would read as the tray
        // glyph growing every time a problem appears).
        let restingRep = try render(MenuBarLogo.image(), canvas: 18, scale: 4)
        let restingExtent = try inkExtent(restingRep, canvas: 18)
        let badgedExtent = try inkExtent(rep, canvas: 20)
        #expect(abs(badgedExtent.width - restingExtent.width) < 0.5)
        #expect(abs(badgedExtent.height - restingExtent.height) < 0.5)
    }

    @Test("the dark-appearance attention face wears white ink and the blue dot")
    func badgedDarkFace() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let badged = MenuBarLogo.badgedImage(for: dark)
        #expect(!badged.isTemplate)

        let rep = try render(badged, canvas: 20, scale: 4)
        let ringRadius: CGFloat = 0.260 * 28
        func rgb(x: CGFloat, y: CGFloat) throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let pixel = NSPoint(
                x: (x * 4).rounded(),
                y: ((20 - y) * 4).rounded()
            )
            let color = try #require(rep.colorAt(x: Int(pixel.x), y: Int(pixel.y)))
                .usingColorSpace(.deviceRGB)
            let resolved = try #require(color)
            return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        }

        // The mark's ink must be white on the dark menu bar, not the template
        // construction's black — a black mark would vanish there.
        let survivor = CGVector(dx: 10 + ringRadius * cos(.pi * 7 / 4 + 0.58), dy: 10 + ringRadius * sin(.pi * 7 / 4 + 0.58))
        let ink = try rgb(x: survivor.dx, y: survivor.dy)
        #expect(ink.r > 0.85, "the mark draws in white ink on the dark face")

        // The dot is blue on the dark face — b dominates r and g — while the
        // mark's ink is white; on the light face both flip per badgedFace.
        let dotCenter = CGVector(dx: 10 + ringRadius * cos(.pi * 7 / 4), dy: 10 + ringRadius * sin(.pi * 7 / 4))
        let darkDot = try rgb(x: dotCenter.dx, y: dotCenter.dy)
        #expect(darkDot.b > darkDot.r + 0.2 && darkDot.b > darkDot.g + 0.2, "the dark face's dot is blue")
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
        #expect(MenuBarLogo.badgedImage(for: .currentDrawing()).size.width > 0)
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
            ("attention", MenuBarLogo.badgedImage(for: .currentDrawing()), 20),
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
