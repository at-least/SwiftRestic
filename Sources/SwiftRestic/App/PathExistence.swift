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

    func check(_ path: String?) async {
        guard let path else { return }
        exists = nil
        let found = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value
        guard !Task.isCancelled else { return }
        exists = found
    }
}
