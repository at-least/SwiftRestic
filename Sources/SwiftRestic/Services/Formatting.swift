import Foundation

/// Shared number and date formatting so every view reads the same way.
///
/// The formatter-backed helpers are paid for per row per render — lists,
/// tables, the once-a-second progress strips — and formatter construction is
/// the expensive half of each call, so the instances are built once. Not all
/// of them are Sendable across SDKs (these helpers also run on the
/// notification broadcast's background task), so every use crosses the lock
/// pattern `ResticDateFormat.parse` already established.
enum Format {
    nonisolated(unsafe) private static let byteCounter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        // ByteCountFormatter spells zero as "Zero KB" by default, which reads
        // as a glitch beside other byte counts.
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
    private static let byteLock = NSLock()

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        byteLock.lock()
        defer { byteLock.unlock() }
        return byteCounter.string(fromByteCount: value)
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }

    /// A count and its noun, spelled for the actual count — the "2 pattern(s)"
    /// style leaks programmer syntax into the interface.
    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        let noun = count == 1 ? singular : plural ?? "\(singular)s"
        return "\(count.formatted(.number)) \(noun)"
    }

    /// The first sentence of a longer message — the part a scan surface can
    /// afford to show, with the rest one selection or tooltip away. Splits on
    /// a period followed by whitespace and then a capital or "restic" (so
    /// "0.5 GB" and "U.S. region" survive whole), a newline, or a CJK full
    /// stop.
    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var cuts = ["\n", "。"].compactMap { trimmed.range(of: $0)?.lowerBound }
        // ". " ends a sentence only when something sentence-shaped follows:
        // a capital starting the next one, or restic — a name that is always
        // spelled lowercase, and opens the wrong-password message's second
        // sentence. Anything else — "U.S. region" — is an abbreviation the
        // cut would have truncated mid-thought.
        var searchEnd = trimmed.startIndex
        while let range = trimmed.range(of: ". ", range: searchEnd..<trimmed.endIndex) {
            let after = range.upperBound
            if after < trimmed.endIndex,
               trimmed[after].isUppercase || trimmed[after...].hasPrefix("restic ") {
                cuts.append(range.lowerBound)
                break
            }
            searchEnd = range.upperBound
        }
        guard let cut = cuts.min() else { return trimmed }
        return String(trimmed[..<cut])
    }

    // Two preconfigured instances, not one mutated per call: `allowedUnits`
    // flips at an hour, and reconfiguring a shared formatter under the lock
    // would make every short duration wait behind every long one — and leak
    // the wrong units if the lock ever widened.
    private static let shortDuration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
    private static let longDuration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
    private static let durationLock = NSLock()

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "<1s" }
        durationLock.lock()
        defer { durationLock.unlock() }
        return (seconds < 3600 ? shortDuration : longDuration).string(from: seconds) ?? "—"
    }

    nonisolated(unsafe) private static let relativeStamp: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private static let relativeLock = NSLock()

    static func relative(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Never" }
        // Something that just happened must not be described in the future
        // tense, which is what a timestamp a fraction of a second old
        // produces. Beyond that window the formatter gets the real date in
        // whichever direction it lies: clamping a future timestamp down to
        // now fed it a zero delta, and a run an hour ahead rendered as the
        // nonsense "in 0 seconds".
        if abs(date.timeIntervalSince(now)) < 45 { return "Just now" }
        relativeLock.lock()
        defer { relativeLock.unlock() }
        return relativeStamp.localizedString(for: date, relativeTo: now)
    }

    /// When a past event happened, as of `now` — the window's minute clock
    /// (`EnvironmentValues.now`), so the same event reads the same on every
    /// surface and moves on with the minute. The tick can be up to a minute
    /// old: an event since then happened "Just now", never "in 50 seconds".
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        return relative(date, now: max(now, date))
    }

    // A value type the cached style is safe to share unlocked, unlike the
    // class formatters above.
    private static let timestampStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(timestampStyle)
    }

    /// The span a group's history was made over — "Sep 28 – Oct 2, 2026",
    /// the adopt sheet's header — each end only as specific as it has to be:
    /// one day says itself, a year both ends share is said once.
    static func historySpan(oldest: Date, newest: Date, calendar: Calendar = .current) -> String {
        func parts(_ date: Date) -> (month: Int, day: Int, year: Int) {
            (calendar.component(.month, from: date), calendar.component(.day, from: date),
             calendar.component(.year, from: date))
        }
        func monthDay(_ parts: (month: Int, day: Int, year: Int)) -> String {
            "\(calendar.shortMonthSymbols[parts.month - 1]) \(parts.day)"
        }
        let old = parts(oldest)
        let new = parts(newest)
        if old.year == new.year {
            return old.month == new.month && old.day == new.day
                ? "\(monthDay(new)), \(new.year)"
                : "\(monthDay(old)) – \(monthDay(new)), \(new.year)"
        }
        return "\(monthDay(old)), \(old.year) – \(monthDay(new)), \(new.year)"
    }

    /// How a file's size moved from the version before — "+17 bytes",
    /// "−1.2 KB" (a minus sign, not a hyphen), or "Same size" — beside a
    /// version row's size, in the sizes' own spelling (`bytes`).
    static func sizeChange(from older: Int64, to newer: Int64) -> String {
        if newer == older { return "Same size" }
        let magnitude = bytes(abs(newer - older))
        return newer > older ? "+\(magnitude)" : "−\(magnitude)"
    }

    /// The day an item a chain's newest backup no longer holds was last
    /// backed up, short for its row in a Files tab — "until Oct 2", the year
    /// said only when it is not this one. The row's tooltip carries the
    /// full moment.
    static func until(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        let day = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? date.formatted(style.month(.abbreviated).day())
            : date.formatted(style.year().month(.abbreviated).day())
        return "until \(day)"
    }

    /// A next-run moment, spelled short for the plan page's Next backup
    /// value (once a stat tile, which truncated `timestamp`'s full "Sep 9,
    /// 2026 at 3:00 AM" right through its AM/PM — the one part that says
    /// morning or evening): near days lead with the day name, and the
    /// value's tooltip carries `timestamp` for the full form. A moment at
    /// or before now reads "Due now".
    static func tileTimestamp(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        guard date > now else { return "Due now" }
        // The calendar owns the time zone: a date the calendar placed at 9 PM
        // must not be re-expressed in the machine's zone (tests pass a fixed
        // one; users simply get their own).
        let zone = calendar.timeZone
        func style() -> Date.FormatStyle {
            Date.FormatStyle(calendar: calendar, timeZone: zone)
        }
        let time = date.formatted(style().hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        { return "Tomorrow \(time)" }
        if date.timeIntervalSince(now) < 7 * 86_400 {
            return "\(date.formatted(style().weekday(.abbreviated))) \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(style().month(.abbreviated).day().hour().minute())
        }
        return date.formatted(style().year().month().day().hour().minute())
    }

    /// When a pause ends, spelled to follow "until": the time alone today,
    /// "tomorrow" for Until Tomorrow's own end (the day, not a midnight
    /// time), "tomorrow 9:00 AM" for another time tomorrow, and further out
    /// the tile's weekday or dated form. An end less than 12 hours ahead is
    /// the time alone even past midnight — "until 12:30 AM" at 11:30 PM is
    /// plain, and nothing redraws the menu bar's VoiceOver label at
    /// midnight, where "tomorrow 12:30 AM" would go on naming a day too
    /// late until the pause ends. (The window's captions are respelled each
    /// minute by its clock, MinuteClock.swift.)
    static func pauseEnd(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let zone = calendar.timeZone
        func style() -> Date.FormatStyle {
            Date.FormatStyle(calendar: calendar, timeZone: zone)
        }
        let time = date.formatted(style().hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            if date == calendar.startOfDay(for: tomorrow) { return "tomorrow" }
            return date.timeIntervalSince(now) < 12 * 3600 ? time : "tomorrow \(time)"
        }
        if date.timeIntervalSince(now) < 7 * 86_400 {
            return "\(date.formatted(style().weekday(.abbreviated))) \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(style().month(.abbreviated).day().hour().minute())
        }
        return date.formatted(style().year().month().day().hour().minute())
    }

    /// What a snapshot's mark says, as its tooltip and its VoiceOver label.
    /// A count when restic named what it could not read — a permanently
    /// unreadable file marks every snapshot, and the number keeps that from
    /// reading as fresh alarm each time. Nil when nothing is known (no run
    /// record, or one from before the exit code was stored), so the mark
    /// makes no claim.
    static func snapshotCompleteness(_ run: RunRecord?) -> String? {
        switch run?.snapshotCompleteness {
        case .incomplete?:
            let unreadable = run?.itemErrorCount ?? 0
            return unreadable > 0
                ? "Incomplete: \(plural(unreadable, "item")) could not be read"
                : "Incomplete: restic could not read some of the source data"
        case .complete?:
            return "Complete"
        case .unknown?, nil:
            return nil
        }
    }

    static func rate(bytes: Int64, over seconds: TimeInterval) -> String {
        guard seconds > 0.5, bytes > 0 else { return "—" }
        let perSecond = Int64(Double(bytes) / seconds)
        return "\(Self.bytes(perSecond))/s"
    }

    /// The root that contains an absolute path, longest match first: a
    /// whole-disk root (`/`) contains every absolute path, and where it
    /// coexists with narrower roots the narrower one is the honest answer.
    /// The naive prefix check (`path.hasPrefix(root + "/")`) can never match
    /// `/` — it would ask for a leading `//`.
    static func containingRoot(of path: String, in roots: [String]) -> String? {
        roots
            .filter { root in
                root == "/"
                    ? path.hasPrefix("/")
                    : (path == root || path.hasPrefix(root + "/"))
            }
            .max { $0.count < $1.count }
    }

    /// The ancestor chain of a path from its containing root down to itself,
    /// inclusive — the spine a tree must be expanded along to bring the path
    /// back on screen. Empty outside every root.
    static func pathChain(of path: String, roots: [String]) -> [String] {
        guard let root = containingRoot(of: path, in: roots) else { return [] }
        var chain = [root]
        let remainder = root == "/" ? path.dropFirst() : path.dropFirst(root.count + 1)
        var walked = root
        for segment in remainder.split(separator: "/") {
            walked = walked == "/" ? "/\(segment)" : walked + "/\(segment)"
            chain.append(walked)
        }
        return chain
    }

    /// Splits an absolute path into clickable crumbs, walking down from the
    /// deepest root that contains it — `/tmp/src/Documents` under root
    /// `/tmp/src` becomes [(src, /tmp/src), (Documents, /tmp/src/Documents)].
    /// Paths outside every root yield no crumbs: navigation never reaches
    /// above the backed-up scope. Root labels are the root's own basename.
    static func crumbs(of path: String, roots: [String]) -> [(label: String, target: String)] {
        pathChain(of: path, roots: roots).map { step in
            let label = step.split(separator: "/").last.map(String.init) ?? step
            return (label, step)
        }
    }

}
