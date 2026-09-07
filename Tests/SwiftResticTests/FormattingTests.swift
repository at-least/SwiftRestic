import Foundation
import Testing

/// The literal branches of the shared formatters: the sentinel strings and the
/// guards around them. Everything a system formatter localises ("1 hr", "5 MB")
/// is asserted only structurally, so the suite does not depend on the test
/// machine's locale.
@Suite("Shared formatting")
struct FormattingTests {
    @Test("missing values read as an em dash, never as an empty string")
    func sentinels() {
        #expect(Format.bytes(nil) == "—")
        #expect(Format.count(nil) == "—")
        #expect(Format.duration(nil) == "—")
        #expect(Format.relative(nil) == "Never")
        #expect(Format.timestamp(nil) == "—")
    }

    @Test("duration rejects anything a clock could not have measured")
    func durationGuards() {
        #expect(Format.duration(-1) == "—")
        #expect(Format.duration(.infinity) == "—")
        #expect(Format.duration(.nan) == "—")
        // Just under a second is not "0s" — it did happen, briefly.
        #expect(Format.duration(0.999) == "<1s")
        // From one second up the formatter takes over, rounding to whole units.
        #expect(Format.duration(1) != "<1s")
        #expect(Format.duration(59.9) != "—")
    }

    @Test("hour-plus runs drop the seconds unit, short ones keep it")
    func durationUnitSwitch() {
        // The allowed units flip at an hour, so a 90-minute run never reads as
        // "1 hr 30 min 0 sec". Pinned to exact literals — an inequality between
        // two different inputs would also survive a broken formatter. (The
        // suite's other pins assume the en locale; so does DateComponentsFormatter.)
        #expect(Format.duration(90) == "1m 30s")
        #expect(Format.duration(90 * 60) == "1h 30m")
        // At the boundary the seconds round away into a whole hour, never a
        // "1h 0m" leaking the dropped unit back in.
        #expect(Format.duration(3600) == "1h")
    }

    @Test("zero bytes stays numeric")
    func zeroBytes() {
        // ByteCountFormatter spells zero as "Zero KB" unless told not to; on an
        // axis or a stat tile that reads as a glitch.
        #expect(!Format.bytes(0).contains("Zero"))
    }

    @Test("counts render digits, not dashes, once a value exists")
    func counts() {
        #expect(Format.count(0) == "0")
    }

    @Test("relative time treats the last few seconds as now, whichever side of it")
    func relativeNow() {
        #expect(Format.relative(Date.now) == "Just now")
        #expect(Format.relative(Date.now.addingTimeInterval(-30)) == "Just now")
        #expect(Format.relative(Date.now.addingTimeInterval(30)) == "Just now")
    }

    @Test("rate refuses to divide by a meaningless duration")
    func rateGuards() {
        #expect(Format.rate(bytes: 1_000, over: 0) == "—")
        #expect(Format.rate(bytes: 1_000, over: 0.5) == "—")
        #expect(Format.rate(bytes: 0, over: 60) == "—")
        #expect(Format.rate(bytes: -5, over: 60) == "—")
        // The per-second suffix is our own literal, not the formatter's.
        #expect(Format.rate(bytes: 1_000, over: 2).hasSuffix("/s"))
    }
}
