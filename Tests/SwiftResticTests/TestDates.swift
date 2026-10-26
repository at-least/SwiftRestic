import Foundation

/// "2026-10-23 09:00:00", read in UTC whatever the Mac's zone, calendar
/// and 12/24-hour setting.
func utcDate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: string)!
}

/// New York's zone in en_US: the pins read "9:00 PM" whatever the Mac's own
/// zone, region and 12/24-hour setting.
func newYorkCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}

/// The narrow no-break space a formatter puts before AM and PM, flattened so
/// a pin compares what it appears to compare.
func flatSpaces(_ value: String) -> String {
    value.replacingOccurrences(of: "\u{202F}", with: " ")
}

/// A snapshot as restic's JSON gives it. `includeShortID: false` and each nil
/// leave that key out, so a fixture can pin what a bare listing decodes to.
func snapshotFixture(
    id: String,
    time: String,
    paths: [String],
    includeShortID: Bool,
    hostname: String?,
    tags: [String]?,
    excludes: [String]? = nil
) throws -> Snapshot {
    // Arrays through JSONEncoder: interpolating a Swift array writes its
    // debug description, whose escaped quotes end up inside the strings.
    let array = { (strings: [String]) in String(decoding: try JSONEncoder().encode(strings), as: UTF8.self) }
    var fields = ["\"id\":\"\(id)\""]
    if includeShortID { fields.append("\"short_id\":\"\(id.prefix(8))\"") }
    fields.append("\"time\":\"\(time)\"")
    fields.append("\"paths\":\(try array(paths))")
    if let hostname { fields.append("\"hostname\":\"\(hostname)\"") }
    if let tags { fields.append("\"tags\":\(try array(tags))") }
    if let excludes { fields.append("\"excludes\":\(try array(excludes))") }
    let json = "{" + fields.joined(separator: ",") + "}"
    return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
}

/// A plan is called by its path's last component, so `name` ends it.
func namedPlan(_ name: String, repositoryID: UUID?) -> BackupPlan {
    var plan = BackupPlan()
    plan.repositoryID = repositoryID
    plan.path = "/Users/someone/\(name)"
    return plan
}

/// A repository is called by where it is: a folder off the startup
/// disk by its own name, so `name` ends the path.
func namedRepository(_ name: String) -> Repository {
    var repository = Repository()
    repository.localPath = "/Users/someone/\(name)"
    return repository
}
