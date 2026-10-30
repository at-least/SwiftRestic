import Foundation
import Testing

/// The one does-this-path-exist check the Show in Finder rows share
/// (`PathExistence`): the ask off the main actor, the answer reset per
/// check, a cancelled check landing nothing.
@Suite("Path existence")
@MainActor
struct PathExistenceTests {
    private func makeFile() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticPathExistence-\(UUID().uuidString)")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("a present path answers true; asked again after the file is gone, false")
    func presentThenGone() async throws {
        let existence = PathExistence()
        let path = try makeFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        await existence.check(path)
        #expect(existence.exists == true)
        try FileManager.default.removeItem(atPath: path)
        await existence.check(path)
        #expect(existence.exists == false)
    }

    @Test("a cancelled re-check of a present path answers nothing: the reset has run, the answer never lands")
    func cancelledRecheckOfPresentPath() async throws {
        let existence = PathExistence()
        let path = try makeFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        await existence.check(path)
        #expect(existence.exists == true)
        // Cancelled before its body runs — the task cannot have started
        // while this synchronous code held the main actor — so the guard
        // never lands, whatever the detached ask's timing.
        let task = Task { await existence.check(path) }
        task.cancel()
        await task.value
        #expect(existence.exists == nil)
    }

    @Test("a cancelled first check of an absent path answers nil, never the false it would have landed")
    func cancelledFirstCheckOfAbsentPath() async {
        let existence = PathExistence()
        let task = Task { await existence.check("/SwiftRestic-no-such-path-\(UUID().uuidString)") }
        task.cancel()
        await task.value
        #expect(existence.exists == nil)
    }

    @Test("a nil path asks nothing and answers nothing: the previous answer stands")
    func nilPathChangesNothing() async throws {
        let existence = PathExistence()
        await existence.check(nil)
        #expect(existence.exists == nil)
        let path = try makeFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        await existence.check(path)
        #expect(existence.exists == true)
        await existence.check(nil)
        #expect(existence.exists == true)
    }
}
