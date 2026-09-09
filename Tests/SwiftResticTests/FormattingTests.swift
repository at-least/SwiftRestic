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

    @Test("a count and its noun agree in number")
    func pluralCounts() {
        #expect(Format.plural(0, "pattern") == "0 patterns")
        #expect(Format.plural(1, "pattern") == "1 pattern")
        #expect(Format.plural(2, "pattern") == "2 patterns")
        // Irregular plurals are spelled out, never auto-s suffixed.
        #expect(Format.plural(3, "entry", "entries") == "3 entries")
        #expect(Format.plural(1, "entry", "entries") == "1 entry")
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

    @Test("relative time stays truthful for a future timestamp")
    func relativeFuture() {
        // The old `min(date, now)` clamp fed the formatter a zero delta, so a
        // run an hour ahead rendered as "in 0 seconds". The exact unit is the
        // formatter's business (3600 s rounds to 59 minutes); future tense is
        // ours.
        let value = Format.relative(Date.now.addingTimeInterval(3_600))
        #expect(value.hasPrefix("in "))
        #expect(!value.contains("0 seconds"))
    }

    @Test("tile timestamps keep the part a tile would truncate — morning or evening")
    func tileTimestamps() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // The formatter separates a time from its meridiem with a narrow
        // no-break space, which is invisible in a test failure's printout —
        // flatten it so a pin compares what it appears to compare.
        func flat(_ value: String) -> String {
            value.replacingOccurrences(of: "\u{202F}", with: " ")
        }
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 9, 9, 10) // a Wednesday, mid-morning

        // A moment that has already passed is due, never a date in the past tense.
        #expect(flat(Format.tileTimestamp(date(2026, 9, 9, 8), now: now, calendar: calendar)) == "Due now")
        #expect(flat(Format.tileTimestamp(date(2026, 9, 9, 21), now: now, calendar: calendar)) == "Today 9:00 PM")
        #expect(flat(Format.tileTimestamp(date(2026, 9, 10, 21), now: now, calendar: calendar)) == "Tomorrow 9:00 PM")
        // Inside the week the day name leads; September 14, 2026 is a Monday.
        #expect(flat(Format.tileTimestamp(date(2026, 9, 14, 21), now: now, calendar: calendar)) == "Mon 9:00 PM")
        // Further out the month leads, and the time is still spelled in full.
        let inDecember = flat(Format.tileTimestamp(date(2026, 12, 24, 21), now: now, calendar: calendar))
        #expect(inDecember.hasSuffix("9:00 PM"))
        #expect(inDecember.contains("Dec"))
        #expect(!inDecember.contains("Today") && !inDecember.contains("Tomorrow"))
        // A different year keeps the year, so the tile cannot imply this December.
        let nextYear = flat(Format.tileTimestamp(date(2027, 12, 24, 21), now: now, calendar: calendar))
        #expect(nextYear.contains("2027"))
        #expect(nextYear.hasSuffix("9:00 PM"))
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

    @Test("firstSentence cuts at the first real sentence boundary")
    func firstSentenceCuts() {
        #expect(
            Format.firstSentence("Repository /Volumes/Photos is not writable: read-only file system")
                == "Repository /Volumes/Photos is not writable: read-only file system",
            "no boundary means the whole message"
        )
        #expect(
            Format.firstSentence("Cannot reach nas.local: connection refused. Check the host and try again.")
                == "Cannot reach nas.local: connection refused",
            "a period followed by a space is a boundary"
        )
        #expect(
            Format.firstSentence("0.5 GB were written. Done.")
                == "0.5 GB were written",
            "a decimal point is not a boundary, but the real sentence end still cuts"
        )
        #expect(Format.firstSentence("first\nsecond") == "first", "a newline is a boundary")
        #expect(Format.firstSentence("  padded  ") == "padded", "whitespace is trimmed")
        #expect(Format.firstSentence("") == "", "empty in, empty out")
    }
}
