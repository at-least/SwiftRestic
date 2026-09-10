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
}
