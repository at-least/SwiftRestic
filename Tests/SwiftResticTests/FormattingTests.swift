import Foundation
import Testing

/// The literal branches of the shared formatters: the sentinel strings and the
/// guards around them. The dates are spelled in `newYorkCalendar()`'s en_US;
/// the other formatters take the machine's locale, and their pins are exact
/// English ("1m 30s"), so the suite assumes an en locale.
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
        #expect(Format.plural(2, "match", "matches") == "2 matches")
    }

    @Test("a snapshot's completeness reads as a count of what could not be read, or not at all")
    func snapshotCompletenessLabels() {
        func backup(exitCode: Int32?, unreadable: Int) -> RunRecord {
            var record = RunRecord(kind: .backup)
            record.snapshotID = "cafe0000"
            record.exitCode = exitCode
            record.itemErrorCount = unreadable
            return record
        }
        #expect(Format.snapshotCompleteness(backup(exitCode: 3, unreadable: 3)) == "Incomplete: 3 items could not be read")
        #expect(Format.snapshotCompleteness(backup(exitCode: 3, unreadable: 1)) == "Incomplete: 1 item could not be read")
        #expect(
            Format.snapshotCompleteness(backup(exitCode: 3, unreadable: 0))
                == "Incomplete: some of the source data could not be read"
        )
        #expect(Format.snapshotCompleteness(backup(exitCode: 0, unreadable: 0)) == "Complete")
        // No exit code and no errors: nothing is known, so nothing is said.
        #expect(Format.snapshotCompleteness(backup(exitCode: nil, unreadable: 0)) == nil)
        #expect(Format.snapshotCompleteness(nil) == nil)
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
        #expect(Format.relative(Date.now) == "just now")
        #expect(Format.relative(Date.now.addingTimeInterval(-30)) == "just now")
        #expect(Format.relative(Date.now.addingTimeInterval(30)) == "just now")
    }

    @Test("relative time stays truthful for a future timestamp")
    func relativeFuture() {
        // A delta clamped to now would render a run an hour ahead as "in 0
        // seconds". The exact unit is the formatter's business (3600 s
        // rounds to 59 minutes); future tense is ours.
        let value = Format.relative(Date.now.addingTimeInterval(3_600))
        #expect(value.hasPrefix("in "))
        #expect(!value.contains("0 seconds"))
    }

    @Test("a past event, as of the window's minute tick, is never in the future")
    func agoAsOfTick() {
        let tick = Date.now.addingTimeInterval(-600)
        // Spelled from the tick, not from whenever the view happened to
        // draw: the same event reads the same everywhere in the window.
        #expect(Format.ago(tick.addingTimeInterval(-3_600), now: tick)
            == Format.relative(tick.addingTimeInterval(-3_600), now: tick))
        // The tick can be up to a minute old. A run that finished since it
        // happened "just now" — Format.relative would say "in 50 seconds".
        #expect(Format.ago(tick.addingTimeInterval(50), now: tick) == "just now")
        #expect(Format.relative(tick.addingTimeInterval(50), now: tick).hasPrefix("in "))
        #expect(Format.ago(nil, now: tick) == "Never")
    }

    @Test("tile timestamps keep the part a tile would truncate — morning or evening")
    func tileTimestamps() {
        let calendar = newYorkCalendar()
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 9, 9, 10) // a Wednesday, mid-morning

        // A moment that has already passed is due, never a date in the past tense.
        #expect(flatSpaces(Format.tileTimestamp(date(2026, 9, 9, 8), now: now, calendar: calendar)) == "Due now")
        #expect(flatSpaces(Format.tileTimestamp(date(2026, 9, 9, 21), now: now, calendar: calendar)) == "Today 9:00 PM")
        #expect(flatSpaces(Format.tileTimestamp(date(2026, 9, 10, 21), now: now, calendar: calendar)) == "Tomorrow 9:00 PM")
        // Inside the week the day name leads; September 14, 2026 is a Monday.
        #expect(flatSpaces(Format.tileTimestamp(date(2026, 9, 14, 21), now: now, calendar: calendar)) == "Mon 9:00 PM")
        // Further out the month leads, and the time is still spelled in full.
        let inDecember = flatSpaces(Format.tileTimestamp(date(2026, 12, 24, 21), now: now, calendar: calendar))
        #expect(inDecember.hasSuffix("9:00 PM"))
        #expect(inDecember.contains("Dec"))
        #expect(!inDecember.contains("Today") && !inDecember.contains("Tomorrow"))
        // A different year keeps the year, so the tile cannot imply this December.
        let nextYear = flatSpaces(Format.tileTimestamp(date(2027, 12, 24, 21), now: now, calendar: calendar))
        #expect(nextYear.contains("2027"))
        #expect(nextYear.hasSuffix("9:00 PM"))
    }

    @Test("a calendar's own locale names the clock: a 24-hour region reads 21:00")
    func twentyFourHourCalendar() {
        var calendar = newYorkCalendar()
        calendar.locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 10))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 21))!
        #expect(flatSpaces(Format.tileTimestamp(evening, now: now, calendar: calendar)) == "Today 21:00")
        #expect(flatSpaces(Format.pauseEnd(evening, now: now, calendar: calendar)) == "21:00")
    }

    @Test("a version's size change is signed in the sizes' own units, and an equal size says so")
    func sizeChanges() {
        #expect(Format.sizeChange(from: 89, to: 106) == "+" + Format.bytes(17))
        #expect(Format.sizeChange(from: 106, to: 89) == "−" + Format.bytes(17))
        #expect(Format.sizeChange(from: 106, to: 106) == "Same size")
    }

    @Test("an item's last backup day reads after until, with the year only when it is another one")
    func untilDays() {
        let calendar = newYorkCalendar()
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 10, 5, 10)
        // 11 PM in New York is the next morning in UTC: the calendar's zone
        // names the day.
        #expect(Format.until(date(2026, 10, 2, 23), now: now, calendar: calendar) == "until Oct 2")
        let lastYear = Format.until(date(2025, 12, 30, 9), now: now, calendar: calendar)
        #expect(lastYear.hasPrefix("until "))
        #expect(lastYear.contains("Dec") && lastYear.contains("30") && lastYear.contains("2025"))
    }

    @Test("a pause end reads naturally after until")
    func pauseEndSpelling() {
        let calendar = newYorkCalendar()
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let now = date(2026, 9, 9, 10) // the tile fixture's Wednesday morning

        #expect(flatSpaces(Format.pauseEnd(date(2026, 9, 9, 15, 40), now: now, calendar: calendar)) == "3:40 PM")
        // Until Tomorrow's own end: the day, not a midnight time.
        #expect(flatSpaces(Format.pauseEnd(date(2026, 9, 10, 0), now: now, calendar: calendar)) == "tomorrow")
        #expect(flatSpaces(Format.pauseEnd(date(2026, 9, 10, 9), now: now, calendar: calendar)) == "tomorrow 9:00 AM")
        #expect(flatSpaces(Format.pauseEnd(date(2026, 9, 14, 21), now: now, calendar: calendar)) == "Mon 9:00 PM")
    }

    @Test("an hour's pause across midnight reads the same before and after it")
    func pauseEndAcrossMidnight() {
        let calendar = newYorkCalendar()
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        // For 1 Hour pressed at 11:30 PM. Nothing redraws the menu bar's
        // VoiceOver label at midnight, so the words written at 11:30 PM are
        // still up at 12:10 AM — where "tomorrow 12:30 AM" would name a day
        // too late. (The window's captions are respelled each minute.)
        let end = date(2026, 9, 27, 0, 30)
        #expect(flatSpaces(Format.pauseEnd(end, now: date(2026, 9, 26, 23, 30), calendar: calendar)) == "12:30 AM")
        #expect(flatSpaces(Format.pauseEnd(end, now: date(2026, 9, 27, 0, 10), calendar: calendar)) == "12:30 AM")
        // Until Tomorrow's own end keeps its word: it lapses at midnight.
        #expect(flatSpaces(Format.pauseEnd(date(2026, 9, 27, 0), now: date(2026, 9, 26, 23, 30), calendar: calendar)) == "tomorrow")
    }

    @Test("repeated and alternating calls keep their own formatting")
    func formatterReuseStaysCorrect() {
        // The formatters behind these helpers are long-lived shared instances
        // (they are paid for per row per render, so construction cannot be the
        // per-call cost). Alternating inputs are exactly the case a reused
        // mutable formatter gets wrong — the sub-hour/hour-plus unit switch
        // leaking from one call into the next — so the pins alternate.
        for _ in 0..<3 {
            #expect(Format.duration(90) == "1m 30s")
            #expect(Format.duration(90 * 60) == "1h 30m")
            #expect(Format.duration(3600) == "1h")
        }
        #expect(!Format.bytes(0).contains("Zero"))
        #expect(Format.bytes(1_500_000) != Format.bytes(3_000_000))
        #expect(Format.relative(Date.now) == "just now")
        #expect(Format.relative(Date.now.addingTimeInterval(-3_600)) != "just now")
    }

    @Test("a timestamp renders a real date, not the sentinel")
    func timestampRenders() {
        // Structural only: the exact spelling is the locale's business.
        let value = Format.timestamp(Date(timeIntervalSince1970: 1_759_000_000))
        #expect(!value.isEmpty)
        #expect(value != "—")
        #expect(value.rangeOfCharacter(from: .decimalDigits) != nil)
    }

    @Test("a sectioned list row's stamp keeps its minutes and drops its year")
    func dayTimeKeepsMinutes() {
        // Structural on the locale like `timestamp`'s pin, plus the two
        // guarantees the row needs: the year's digits are gone (the month
        // section header says them), the minutes are not — a truncated tail
        // once read 10:19 AM and 10:19 PM as one row.
        let value = Format.dayTime(Date(timeIntervalSince1970: 1_759_000_000))
        #expect(!value.isEmpty)
        #expect(!value.contains("2025"))
        #expect(value.contains(":"))
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
        #expect(
            Format.firstSentence("The run failed in U.S. region 2 and was stopped.")
                == "The run failed in U.S. region 2 and was stopped.",
            "a capital-less continuation after '. ' is an abbreviation, not a boundary"
        )
        // restic is a name spelled lowercase, and it starts the second
        // sentence of the wrong-password message.
        let wrongPassword = ResticError.commandFailed(
            exitCode: 12, message: "Fatal: wrong password or no key found"
        )
        #expect(
            Format.firstSentence(wrongPassword.localizedDescription)
                == "The password doesn’t open this repository — check it in the repository editor",
            "a sentence that starts with restic is still a sentence"
        )
        #expect(Format.firstSentence("first\nsecond") == "first", "a newline is a boundary")
        #expect(Format.firstSentence("  padded  ") == "padded", "whitespace is trimmed")
        #expect(Format.firstSentence("") == "", "empty in, empty out")
    }

    @Test("pathChain walks down from the deepest containing root")
    func pathChainWalksDown() {
        let roots = ["/tmp/src", "/other"]

        // A deep path: the root plus one step per level below it.
        #expect(Format.pathChain(of: "/tmp/src/Documents/Reports", roots: roots)
            == ["/tmp/src", "/tmp/src/Documents", "/tmp/src/Documents/Reports"])

        // The root itself is a single step.
        #expect(Format.pathChain(of: "/tmp/src", roots: roots) == ["/tmp/src"])

        // A path outside every root yields nothing to walk.
        #expect(Format.pathChain(of: "/elsewhere/thing", roots: roots).isEmpty)

        // A root that is a prefix of another root's name must not match it.
        #expect(Format.pathChain(of: "/other/file", roots: ["/other Extended", "/other"]) == ["/other", "/other/file"])
    }

    @Test("a whole-disk root chains every absolute path")
    func rootSlashMatchesEverything() {
        // "/" contains every absolute path: the naive prefix check
        // (`path.hasPrefix(root + "/")` → "//") matches nothing at all.

        // The ancestor chain the restore browser re-opens walks from "/" too.
        #expect(Format.pathChain(of: "/etc/hosts", roots: ["/"]) == ["/", "/etc", "/etc/hosts"])
        #expect(Format.pathChain(of: "/", roots: ["/"]) == ["/"])
    }

    @Test("the containing root is the longest match, not the first")
    func longestRootWins() {
        // A whole-disk plan may coexist with narrower roots (a second plan on
        // the same repository): "/Users/x" is the honest root there.
        #expect(Format.pathChain(of: "/Users/x/f.txt", roots: ["/", "/Users/x"])
            == ["/Users/x", "/Users/x/f.txt"])

        // Outside every narrower root, "/" still answers.
        #expect(Format.pathChain(of: "/etc/hosts", roots: ["/", "/Users/x"]) == ["/", "/etc", "/etc/hosts"])

        // No root at all: nothing to chain.
        #expect(Format.pathChain(of: "/etc/hosts", roots: []) == [])
    }

}
