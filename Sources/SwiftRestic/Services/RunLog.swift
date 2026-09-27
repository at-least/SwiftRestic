import Foundation

/// The versions a run's log and Copy Details lead with — what a forum
/// thread asks first.
struct RunLogVersions: Sendable, Equatable {
    /// "SwiftRestic 0.1.0 (1)".
    var app: String
    /// "macOS 26.6.2 (Build 25G83)".
    var macOS: String
    /// restic's own `version` line.
    var restic: String

    /// This build, this Mac, and the restic the app located. The bundle is
    /// the one this code was built into — the app itself, or the test
    /// bundle under xctest, whose main bundle is the runner's.
    static func current(resticVersion: String) -> RunLogVersions {
        let info = Bundle(for: RunTranscript.self).infoDictionary
        var app = "SwiftRestic"
        if let short = info?["CFBundleShortVersionString"] as? String { app += " \(short)" }
        if let build = info?["CFBundleVersion"] as? String { app += " (\(build))" }
        // "Version 26.6.2 (Build 25G83)" (probe) — the prefix is Foundation's.
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let macOS = "macOS " + (system.hasPrefix("Version ") ? String(system.dropFirst("Version ".count)) : system)
        let restic = resticVersion
            .split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return RunLogVersions(app: app, macOS: macOS, restic: restic.isEmpty ? "restic version unknown" : restic)
    }
}

/// The plain-text log of one run: a header naming the versions and the
/// run, every transcript entry with its time and a stream tag, and a footer
/// with the verdict. restic's lines are written verbatim — the log is a
/// diagnostic record of what restic printed, and exactness beats
/// prettiness. The header names the repository by name and kind only, never
/// by location, which can carry a host, a bucket or a user name — restic's
/// own error lines may still name it, with a URL's password masked as `***`
/// (probed against a `rest:` URL on 0.19.1).
enum RunLog {
    static func render(
        record: RunRecord,
        repositoryName: String?,
        repositoryKind: String?,
        versions: RunLogVersions,
        transcript: RunTranscript.Contents,
        timeZone: TimeZone = .current
    ) -> String {
        let clock = formatter("HH:mm:ss", timeZone: timeZone)
        let stamp = formatter("yyyy-MM-dd HH:mm:ss Z", timeZone: timeZone)
        let repository = repositoryName.map { name in
            "repository “\(name)”" + (repositoryKind.map { " (\($0))" } ?? "")
        } ?? "repository no longer set up in SwiftRestic"

        var lines = [
            "\(versions.app) · \(versions.macOS)",
            versions.restic,
            "\(RunRecordPresentation.subject(of: record)) — \(repository)",
            "Started \(stamp.string(from: record.startedAt))",
            "",
        ]
        if transcript.entries.isEmpty {
            lines.append("No restic command ran.")
        }
        for (index, entry) in transcript.entries.enumerated() {
            if index == transcript.headCount, transcript.omittedLineCount > 0 {
                lines.append("… \(Format.plural(transcript.omittedLineCount, "line")) omitted …")
            }
            // restic's lines arrive one per entry; an app-written note can
            // carry restic's multi-line words (a lock refusal inside
            // "Retention skipped: …"), whose later lines stay under the text
            // column instead of passing for untagged output at the margin.
            let prefix = "\(clock.string(from: entry.time)) \(tag(for: entry.kind)) "
            let pieces = entry.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            lines.append(prefix + (pieces.first.map(String.init) ?? ""))
            let indent = String(repeating: " ", count: prefix.count)
            lines += pieces.dropFirst().map { indent + $0 }
        }

        lines.append("")
        lines.append(
            "Finished \(stamp.string(from: record.finishedAt)) after \(Format.duration(record.duration)) — \(record.outcome.displayName)"
        )
        // A cancellation's message only repeats the verdict.
        if let failure = record.failureMessage, failure != record.outcome.displayName {
            lines.append(failure)
        }
        if let snapshotID = record.snapshotID {
            lines.append("Snapshot \(snapshotID)")
        }
        switch record.kind {
        case .backup where RunRecordPresentation.hasBackupNumbers(record):
            lines.append(
                "Files: \(record.filesNew) new, \(record.filesChanged) changed, \(record.filesUnmodified) unmodified"
                    + " · processed \(Format.bytes(record.bytesProcessed)) · added \(Format.bytes(record.dataAdded))"
            )
        case .check:
            if let result = record.detailText { lines.append("Result: \(result)") }
        case .restore:
            if record.outcome == .succeeded {
                lines.append(
                    "Restored \(Format.plural(record.filesRestored, "file")), \(Format.bytes(record.bytesProcessed));"
                        + " \(record.filesSkipped) \(RunRecordPresentation.kept(record.filesSkipped))"
                )
                if let destination = record.destinationPath { lines.append("Restored to \(destination)") }
            } else if let destination = record.destinationPath {
                lines.append("Destination \(destination)")
            }
        default:
            break
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Four characters wide, so restic's words line up in one column.
    private static func tag(for kind: RunTranscript.Entry.Kind) -> String {
        switch kind {
        case .command: "$   "
        case .output(.stdout): "out "
        case .output(.stderr): "err "
        case .exit: "exit"
        case .note: "note"
        }
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

/// Where run logs live: `Logs/<run-id>.log` beside `config.json`, so they
/// follow `SWIFTRESTIC_CONFIG_DIR` and a capture or test run never touches
/// the real ones. Every method is synchronous file work — callers run it
/// detached, never on the main actor — and only files named `<UUID>.log`
/// are ever removed.
struct RunLogStore: Sendable {
    let directory: URL

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).log")
    }

    func write(_ text: String, for id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url(for: id), options: .atomic)
    }

    func read(_ id: UUID) -> String? {
        try? String(contentsOf: url(for: id), encoding: .utf8)
    }

    /// The logs of runs leaving the history. A missing file is fine — a
    /// record from before logs, or one whose write failed, has none.
    func remove(_ ids: some Sequence<UUID>) {
        for id in ids {
            try? FileManager.default.removeItem(at: url(for: id))
        }
    }

    /// Removes `<UUID>.log` files no record in `keeping` names, and only
    /// those last written before `cutoff` — a run finishing while the sweep
    /// walks the folder writes its log after the cutoff, before its record
    /// reaches the history the caller read. Returns how many went.
    @discardableResult
    func sweep(keeping: Set<UUID>, olderThan cutoff: Date) -> Int {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where name.hasSuffix(".log") {
            guard let id = UUID(uuidString: String(name.dropLast(".log".count))), !keeping.contains(id) else {
                continue
            }
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
