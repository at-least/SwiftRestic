import Foundation

/// Tolerant accessors for decoding the stored configuration.
///
/// The synthesized `Decodable` conformance requires every key to be present, so
/// a `config.json` written before a field existed fails to decode outright — and
/// for a backup app that means silently losing every schedule and repository the
/// user had set up. Every persisted model decodes through these instead, so an
/// unknown, missing or malformed field falls back to its default rather than
/// taking the whole document down with it.
///
/// Tolerance is not silence: a field that is *present* but unreadable is a
/// reporting gap, not a missing key. When a `DecodeNoteBox` is bound around
/// the decoding pass (`DecodeNotes.$current.withValue`, as the config store
/// does), every such fallback is recorded there so the app can say what was
/// substituted — an unknown enum value silently becoming `.local` would
/// otherwise repoint a repository without a word, and the next save would
/// persist the substitution.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        guard contains(key) else { return fallback }
        do {
            if let decoded = try decodeIfPresent(T.self, forKey: key) { return decoded }
            note(key, "is null — the default (\(fallback)) is used")
            return fallback
        } catch {
            note(key, "could not be read (\(Self.briefFailure(error))) — the default (\(fallback)) is used")
            return fallback
        }
    }

    func optional<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        guard contains(key) else { return nil }
        do {
            if let decoded = try decodeIfPresent(T.self, forKey: key) { return decoded }
            note(key, "is null — read as absent")
            return nil
        } catch {
            note(key, "could not be read (\(Self.briefFailure(error))) — read as absent")
            return nil
        }
    }

    private static func briefFailure(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return String(describing: type(of: error))
        }
        switch decoding {
        case .typeMismatch: return "unexpected type"
        case .valueNotFound: return "a value was missing"
        case .keyNotFound: return "a required key was absent"
        case .dataCorrupted: return "the data is corrupt"
        @unknown default: return "it did not decode"
        }
    }

    /// Reports one tolerant fallback to the bound note box, if there is one.
    /// Silent without a box — models decoded bare record nothing.
    private func note(_ key: Key, _ reason: String) {
        guard let box = DecodeNotes.current else { return }
        box.add("“\(Self.fieldName(in: codingPath, key: key))” \(reason)")
    }

    /// `repositories[0].kind` — indices bracketed, names dot-separated.
    private static func fieldName(in path: [any CodingKey], key: any CodingKey) -> String {
        var field = ""
        for component in path + [key] {
            if let index = component.intValue {
                field += "[\(index)]"
            } else {
                field = field.isEmpty ? component.stringValue : field + "." + component.stringValue
            }
        }
        return field
    }
}

/// The tolerant fallbacks of one decoding pass. Decoding is synchronous
/// inside the `withValue` closure that binds the box, so it never crosses an
/// isolation boundary; the lock exists so the type can honestly claim
/// `Sendable`, which binding a task-local value requires.
enum DecodeNotes {
    /// Bound around a decoding pass; tolerant fallbacks record themselves here.
    @TaskLocal static var current: DecodeNoteBox?
}

final class DecodeNoteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func add(_ note: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(note)
    }

    var notes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
