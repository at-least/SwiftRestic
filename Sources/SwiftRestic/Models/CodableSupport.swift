import Foundation

/// Tolerant decoding of the stored configuration. Synthesized `Decodable`
/// fails on a missing key, which would take every schedule and repository
/// down with one field. A persisted model with defaults decodes through
/// these: a missing or malformed field falls back to its default. One with
/// nothing to fall back to (`NetworkShare`, `SchedulePause`) decodes
/// strictly, and the field holding it falls back whole.
///
/// A present but unreadable field is recorded in the bound `DecodeNoteBox`
/// (the config store binds one), so the app says what it substituted: an
/// unknown enum value silently becoming `.local` would repoint a repository,
/// and the next save would persist it.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        guard contains(key) else { return fallback }
        return read(key, substitute: "the default (\(fallback)) is used") ?? fallback
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        guard contains(key) else { return nil }
        return read(key, substitute: "read as absent")
    }

    private func read<T: Decodable>(_ key: Key, substitute: @autoclosure () -> String) -> T? {
        do {
            if let decoded = try decodeIfPresent(T.self, forKey: key) { return decoded }
            note(key, "is null — \(substitute())")
        } catch {
            note(key, "couldn’t be read (\(Self.briefFailure(error))) — \(substitute())")
        }
        return nil
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

    private func note(_ key: Key, _ reason: String) {
        guard let box = DecodeNotes.current else { return }
        box.add(field: Self.fieldName(in: codingPath, key: key), reason)
    }

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

/// The tolerant fallbacks of one decoding pass. Decoding runs synchronously
/// inside `withValue`; the box's lock exists only because a task-local value
/// must be `Sendable`.
enum DecodeNotes {
    @TaskLocal static var current: DecodeNoteBox?
}

final class DecodeNoteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(field: String, detail: String)] = []

    fileprivate func add(field: String, _ detail: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append((field, detail))
    }

    var notes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map { "“\($0.field)” \($0.detail)" }
    }
}

extension Sequence where Element: Identifiable, Element.ID == UUID {
    func withID(_ id: UUID?) -> Element? {
        id.flatMap { wanted in first { $0.id == wanted } }
    }
}
