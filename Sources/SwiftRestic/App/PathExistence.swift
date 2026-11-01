import Foundation

/// One row's does-this-path-still-exist answer, asked off the main actor: a
/// destination on an unreachable network volume can stall `fileExists`, and
/// the render path must never wait on that. Nil until the check lands —
/// Show in Finder waits disabled until then. Nil asks nothing and answers
/// nothing; a cancelled check — the row or run moved on — lands nothing, so
/// the answer stays nil, not the previous one.
@MainActor
@Observable
final class PathExistence {
    private(set) var exists: Bool?
    private let read: @Sendable (String) -> Bool

    init(read: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.read = read
    }

    func check(_ path: String?) async {
        guard let path else { return }
        exists = nil
        let found = await BlockingRead.run { [read] in read(path) }
        guard !Task.isCancelled else { return }
        exists = found
    }
}
