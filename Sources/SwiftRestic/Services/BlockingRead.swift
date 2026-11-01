import Foundation

/// A file-system read that may stall — a path on a network share that went
/// away — run on a GCD thread of its own.
///
/// Not `Task.detached`: that runs on Swift's shared pool, one thread per
/// core, and each stalled read holds one. Fifteen stalled reads on a
/// 15-core Mac left the next utility-priority task (the index's reads run
/// there) waiting for them to come back. GCD adds threads when its own
/// block, so a stall costs only its own wait.
enum BlockingRead {
    static func run<T: Sendable>(_ read: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: read())
            }
        }
    }
}
