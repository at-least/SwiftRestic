import Foundation
import Testing

/// Every literal in this file is real output captured from restic 0.19.1.
/// This is the layer that breaks silently when restic changes its JSON, so the
/// fixtures are kept verbatim rather than hand-written.
@Suite("restic JSON decoding")
struct ResticMessageTests {
    @Test("backup status line")
    func backupStatus() throws {
        let line = #"{"message_type":"status","percent_done":0.925,"total_files":40,"files_done":33,"total_bytes":80000000,"bytes_done":74000000,"current_files":["/tmp/data2/f7.bin"]}"#
        guard case let .status(status)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a status message")
            return
        }
        #expect(status.percentDone == 0.925)
        #expect(status.totalFiles == 40)
        #expect(status.filesDone == 33)
        #expect(status.bytesDone == 74_000_000)
        #expect(status.currentFiles == ["/tmp/data2/f7.bin"])
    }

    @Test("restore status reuses message_type but renames its counters")
    func restoreStatus() throws {
        let line = #"{"message_type":"status","percent_done":1,"total_files":40,"files_restored":40,"total_bytes":80000000,"bytes_restored":80000000}"#
        guard case let .status(status)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a status message")
            return
        }
        // files_restored / bytes_restored must land in the same fields as the
        // backup spelling, or restore progress shows as zero.
        #expect(status.filesDone == 40)
        #expect(status.bytesDone == 80_000_000)
        #expect(status.fractionComplete == 1)
    }

    @Test("backup --verbose reports each file as a verbose_status line")
    func backupVerboseStatus() throws {
        // Captured verbatim from restic 0.19.1 (`backup --verbose --json`).
        // The struct keeps the fields the app shows; the extra `_in_repo` and
        // `total_files` keys must simply be tolerated.
        let line = #"{"message_type":"verbose_status","action":"new","item":"/restic-capture/src/a.txt","duration":0.004700167,"data_size":12,"data_size_in_repo":94,"metadata_size":0,"metadata_size_in_repo":0,"total_files":0}"#
        guard case let .verboseStatus(verbose)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a verbose_status message")
            return
        }
        #expect(verbose.action == "new")
        #expect(verbose.item == "/restic-capture/src/a.txt")
        #expect(verbose.dataSize == 12)
        #expect(verbose.duration != nil)
    }

    @Test("restore --verbose=2 spells the size `size`, not `data_size`")
    func restoreVerboseStatus() throws {
        // Captured verbatim from restic 0.19.1 (`restore --json --verbose=2`).
        // The two commands disagree on the field name; decoding only the backup
        // spelling would leave every restore line without a size.
        let line = #"{"message_type":"verbose_status","action":"restored","item":"/restic-capture/src/sub/b.txt","size":7}"#
        guard case let .verboseStatus(verbose)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a verbose_status message")
            return
        }
        #expect(verbose.action == "restored")
        #expect(verbose.item == "/restic-capture/src/sub/b.txt")
        #expect(verbose.size == 7)
        #expect(verbose.dataSize == nil)
    }

    @Test("backup summary")
    func backupSummary() throws {
        let line = #"{"message_type":"summary","files_new":3,"files_changed":0,"files_unmodified":0,"dirs_new":8,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":3,"tree_blobs":9,"data_added":304224,"data_added_packed":303244,"total_files_processed":3,"total_bytes_processed":300019,"total_duration":0.714604875,"backup_start":"2026-09-05T00:53:25.22662+08:00","backup_end":"2026-09-05T00:53:25.941226+08:00","snapshot_id":"6ed59088467b1e0388a3bb3b63f3cee920b9de2b69e082544441e1e7d5c56443"}"#
        guard case let .summary(summary)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a summary message")
            return
        }
        #expect(summary.filesNew == 3)
        #expect(summary.dataAdded == 304_224)
        #expect(summary.totalBytesProcessed == 300_019)
        #expect(summary.snapshotID?.hasPrefix("6ed59088") == true)
        #expect(summary.backupStart != nil)
        #expect(summary.backupEnd != nil)
    }

    @Test("restore summary carries the restored counters, not backup's")
    func restoreSummary() throws {
        // Captured verbatim from restic 0.19.1 (`restore --json`).
        let line = #"{"message_type":"summary","total_files":6,"files_restored":6,"total_bytes":307219,"bytes_restored":307219}"#
        guard case let .summary(summary)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a summary message")
            return
        }
        #expect(summary.filesRestored == 6)
        #expect(summary.bytesRestored == 307_219)
        #expect(summary.totalFiles == 6)
        // A restore has no snapshot, so the backup-only fields stay empty
        // rather than masquerading as zeros.
        #expect(summary.snapshotID == nil)
        #expect(summary.filesNew == nil)
    }

    @Test("check summary shares message_type with backup but has disjoint fields")
    func checkSummary() throws {
        let line = #"{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}"#
        guard case let .summary(summary)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a summary message")
            return
        }
        #expect(summary.numErrors == 0)
        #expect(summary.suggestPrune == false)
        #expect(summary.filesNew == nil)
    }

    @Test("backup errors nest the text, check errors do not")
    func errorShapes() throws {
        let backupError = #"{"message_type":"error","error":{"message":"permission denied"},"during":"archival","item":"/private/etc/x"}"#
        guard case let .error(nested)? = ResticMessageDecoder.decode(line: backupError) else {
            Issue.record("expected an error message")
            return
        }
        #expect(nested.message == "permission denied")
        #expect(nested.item == "/private/etc/x")

        // `check` emits a flat `message`. Before this was handled, every check
        // error decoded as .unknown and vanished from the run record.
        let checkError = #"{"message_type":"error","message":"pack 1234 is damaged"}"#
        guard case let .error(flat)? = ResticMessageDecoder.decode(line: checkError) else {
            Issue.record("expected an error message")
            return
        }
        #expect(flat.message == "pack 1234 is damaged")
        #expect(flat.item == nil)
    }

    @Test("fatal exit_error carries restic's own exit code")
    func exitError() throws {
        let line = #"{"message_type":"exit_error","code":12,"message":"Fatal: wrong password or no key found"}"#
        guard case let .exitError(error)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected an exit_error message")
            return
        }
        #expect(error.code == 12)
        #expect(error.message.contains("wrong password"))
    }

    @Test("init")
    func initialized() throws {
        let line = #"{"message_type":"initialized","id":"67f2ecdf39b4ed06","repository":"/tmp/repo"}"#
        guard case let .initialized(info)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected an initialized message")
            return
        }
        #expect(info.repository == "/tmp/repo")
    }

    @Test("ls node line")
    func lsNode() throws {
        let line = #"{"name":"a.txt","type":"file","path":"/tmp/data/a.txt","uid":501,"gid":0,"size":12,"mode":420,"permissions":"-rw-r--r--","mtime":"2026-09-05T00:53:22.569070751+08:00","atime":"2026-09-05T00:53:22.569070751+08:00","ctime":"2026-09-05T00:53:22.569070751+08:00","inode":25178103,"message_type":"node","struct_type":"node"}"#
        guard case let .node(node)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a node message")
            return
        }
        #expect(node.name == "a.txt")
        #expect(node.type == .file)
        #expect(node.size == 12)
        #expect(node.isDirectory == false)
        #expect(node.mtime != nil)
    }

    @Test("ls emits a snapshot header before the nodes")
    func lsSnapshotHeader() throws {
        let line = #"{"time":"2026-09-05T00:53:25.22662+08:00","tree":"141d1b6c","paths":["/tmp/data"],"hostname":"mac","username":"newlix","uid":501,"gid":20,"program_version":"restic 0.19.1","id":"6ed59088467b1e0388a3bb3b63f3cee920b9de2b69e082544441e1e7d5c56443","short_id":"6ed59088","message_type":"snapshot","struct_type":"snapshot"}"#
        guard case let .snapshot(snapshot)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a snapshot message")
            return
        }
        #expect(snapshot.shortID == "6ed59088")
        #expect(snapshot.paths == ["/tmp/data"])
        #expect(snapshot.tags.isEmpty)
    }

    @Test("short_id is deprecated upstream, so it must be derivable from id")
    func shortIDFallback() throws {
        let line = #"{"time":"2026-09-05T00:53:25.22662+08:00","paths":["/tmp/data"],"id":"6ed59088467b1e0388a3bb3b63f3cee920b9de2b69e082544441e1e7d5c56443","message_type":"snapshot"}"#
        guard case let .snapshot(snapshot)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a snapshot message")
            return
        }
        #expect(snapshot.shortID == "6ed59088")
    }

    @Test("timestamps with a variable-length fractional part")
    func timestampParsing() throws {
        // restic prints however many digits Go's time package produced: 5 here,
        // 6 and 9 elsewhere in the same stream. Parsing must land on the right
        // instant — run records and chart bins derive from these — but
        // ISO8601DateFormatter keeps only the first three fraction digits
        // (verified: .22662 parses back out as .226), so the pin is to the
        // millisecond the formatter actually preserves.
        func instant(
            _ year: Int, _ month: Int, _ day: Int,
            _ hour: Int, _ minute: Int, _ second: Int,
            nanosecond: Int = 0, utcOffsetHours: Int
        ) throws -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            components.nanosecond = nanosecond
            components.timeZone = TimeZone(secondsFromGMT: utcOffsetHours * 3600)
            return try #require(Calendar(identifier: .gregorian).date(from: components))
        }
        // Just over the formatter's 1 ms truncation; Double epoch rounding at
        // 2026 is orders of magnitude below this, so anything past it is a
        // real misread, not float noise.
        let tolerance: TimeInterval = 0.002
        let samples: [(String, Date)] = [
            ("2026-09-05T00:53:25.22662+08:00",
             try instant(2026, 9, 5, 0, 53, 25, nanosecond: 226_620_000, utcOffsetHours: 8)),
            ("2026-09-05T00:53:25.941226+08:00",
             try instant(2026, 9, 5, 0, 53, 25, nanosecond: 941_226_000, utcOffsetHours: 8)),
            ("2026-08-31T17:21:46.156199647+08:00",
             try instant(2026, 8, 31, 17, 21, 46, nanosecond: 156_199_647, utcOffsetHours: 8)),
            ("2026-09-05T00:53:25Z",
             try instant(2026, 9, 5, 0, 53, 25, utcOffsetHours: 0)),
        ]
        for (sample, expected) in samples {
            let parsed = try #require(ResticDateFormat.parse(sample), "failed to parse \(sample)")
            #expect(
                abs(parsed.timeIntervalSince(expected)) < tolerance,
                "\(sample) parsed as \(parsed), expected \(expected)"
            )
        }
    }

    @Test("snapshots --json is an array, not a message stream")
    func snapshotsArray() throws {
        let json = #"[{"time":"2026-09-05T00:53:25.22662+08:00","tree":"141d1b6c","paths":["/tmp/data"],"hostname":"mac","username":"newlix","uid":501,"gid":20,"program_version":"restic 0.19.1","summary":{"files_new":3,"data_added":304224,"total_files_processed":3,"total_bytes_processed":300019},"id":"6ed59088467b1e0388a3bb3b63f3cee920b9de2b69e082544441e1e7d5c56443","short_id":"6ed59088"}]"#
        let snapshots = try ResticMessageDecoder.jsonDecoder.decode(
            [Snapshot].self,
            from: Data(json.utf8)
        )
        #expect(snapshots.count == 1)
        #expect(snapshots[0].dataAdded == 304_224)
        #expect(snapshots[0].totalFilesProcessed == 3)
    }

    @Test("stats --mode raw-data")
    func stats() throws {
        let json = #"{"total_size":80314095,"total_uncompressed_size":80328265,"compression_ratio":1.0001764322937337,"compression_progress":100,"compression_space_saving":0.017640117087058815,"total_blob_count":105,"snapshots_count":2}"#
        let stats = try ResticMessageDecoder.jsonDecoder.decode(
            RepositoryStats.self,
            from: Data(json.utf8)
        )
        #expect(stats.totalSize == 80_314_095)
        #expect(stats.totalBlobCount == 105)
        #expect(stats.snapshotsCount == 2)
    }

    @Test("non-JSON stdout is ignored rather than crashing the parser")
    func garbageLines() {
        #expect(ResticMessageDecoder.decode(line: "") == nil)
        #expect(ResticMessageDecoder.decode(line: "restic 0.19.1 compiled with go1.26.5") == nil)
        #expect(ResticMessageDecoder.decode(line: "{ not json") == nil)
    }

    @Test("an unrecognised message_type degrades instead of failing")
    func unknownMessageType() {
        guard case let .unknown(type)? = ResticMessageDecoder.decode(
            line: #"{"message_type":"something_new","x":1}"#
        ) else {
            Issue.record("expected an unknown message")
            return
        }
        #expect(type == "something_new")
    }

    @Test("forget --json reports removals per group")
    func forgetCounting() {
        let output = #"[{"tags":null,"host":"mac","paths":["/tmp/data"],"keep":[{"id":"a"}],"remove":[{"id":"b"},{"id":"c"}],"reasons":[]},{"tags":null,"host":"mac","paths":["/tmp/data2"],"keep":[{"id":"d"}],"remove":null,"reasons":[]}]"#
        #expect(ResticService.countRemoved(forgetOutput: output) == 2)
        #expect(ResticService.countRemoved(forgetOutput: "") == 0)
    }
}

@Suite("restic find decoding")
struct FindDecodingTests {
    @Test("find --json returns matches grouped by snapshot")
    func decodesFindOutput() throws {
        // Captured verbatim from restic 0.19.1.
        let json = #"[{"matches":[{"path":"/tmp/data/a.txt","permissions":"-rw-r--r--","type":"file","mode":420,"mtime":"2026-09-05T00:53:22.569070751+08:00","atime":"2026-09-05T00:53:22.569070751+08:00","ctime":"2026-09-05T00:53:22.569070751+08:00","uid":501,"gid":0,"user":"newlix","group":"wheel","inode":25178103,"device_id":16777229,"size":12,"links":1}],"hits":1,"snapshot":"6ed59088467b1e0388a3bb3b63f3cee920b9de2b69e082544441e1e7d5c56443"}]"#
        let results = try ResticMessageDecoder.jsonDecoder.decode([FindResult].self, from: Data(json.utf8))
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.hits == 1)
        #expect(result.snapshot.hasPrefix("6ed59088"))

        let match = try #require(result.matches.first)
        #expect(match.name == "a.txt")
        #expect(match.size == 12)
        #expect(!match.isDirectory)
        #expect(match.mtime != nil)
    }

    @Test("a match converts to the node shape the restore code takes")
    func matchToNode() throws {
        let json = #"{"path":"/tmp/data/sub","type":"dir","size":0,"mtime":"2026-09-05T00:53:22Z"}"#
        let match = try ResticMessageDecoder.jsonDecoder.decode(FindMatch.self, from: Data(json.utf8))
        #expect(match.isDirectory)
        let node = match.node
        #expect(node.name == "sub")
        #expect(node.path == "/tmp/data/sub")
        #expect(node.type == .dir)
        #expect(node.isDirectory)
    }

    @Test("diff change lines, including restic's concatenated modifiers")
    func diffChange() throws {
        let lines = [
            #"{"message_type":"change","path":"/src/a.txt","modifier":"M"}"#,
            #"{"message_type":"change","path":"/src/newdir/","modifier":"+"}"#,
            #"{"message_type":"change","path":"/src/sub/b.txt","modifier":"-"}"#,
            #"{"message_type":"change","path":"/src/c.txt","modifier":"TU"}"#,
            #"{"message_type":"change","path":"/src/","modifier":"U"}"#,
        ]
        var changes: [ResticDiffChange] = []
        for line in lines {
            guard case let .change(change)? = ResticMessageDecoder.decode(line: line) else {
                Issue.record("expected a change message for \(line)")
                return
            }
            changes.append(change)
        }
        #expect(changes.map(\.category) == [.modified, .added, .removed, .modified, .metadataOnly])
        #expect(changes[1].isDirectory)
        #expect(changes[1].name == "newdir")
        #expect(changes[0].name == "a.txt")
        // A file that became a symlink and lost its mode bits arrives as "TU":
        // the type change is what matters, and the raw flags stay readable.
        #expect(changes[3].modifier == "TU")
        #expect(changes[3].explanation == "type changed, metadata changed")
    }

    @Test("diff statistics")
    func diffStatistics() throws {
        let line = #"{"message_type":"statistics","source_snapshot":"bfdafeae","target_snapshot":"d5fc2a53","changed_files":1,"added":{"files":1,"dirs":1,"others":0,"data_blobs":2,"tree_blobs":3,"bytes":1874},"removed":{"files":1,"dirs":0,"others":0,"data_blobs":2,"tree_blobs":3,"bytes":1500}}"#
        guard case let .statistics(stats)? = ResticMessageDecoder.decode(line: line) else {
            Issue.record("expected a statistics message")
            return
        }
        #expect(stats.changedFiles == 1)
        #expect(stats.added.files == 1)
        #expect(stats.added.dirs == 1)
        #expect(stats.added.bytes == 1874)
        #expect(stats.removed.files == 1)
        #expect(stats.removed.bytes == 1500)
        // Echoes the command line, so it is a short ID here.
        #expect(stats.sourceSnapshot == "bfdafeae")
    }
}
