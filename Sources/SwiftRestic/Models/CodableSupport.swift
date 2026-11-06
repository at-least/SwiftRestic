import Foundation

/// Tolerant accessors for decoding the stored configuration.
///
/// The synthesized `Decodable` conformance requires every key to be present,
/// so a `config.json` written before a field existed would fail to decode —
/// taking every schedule and repository down with it. A persisted model
/// whose fields have defaults decodes through these instead: an unknown,
/// missing or malformed field falls back to its default. One with nothing
/// to fall back to (`NetworkShare`, `SchedulePause`) decodes strictly, and
/// the field holding it falls back whole.
///
/// Tolerance is not silence: a field that is *present* but unreadable is a
/// reporting gap, not a missing key. With a `DecodeNoteBox` bound around the
/// decoding pass (`DecodeNotes.$current.withValue`, as the config store
/// does), every such fallback is recorded there, so the app can say what was
/// substituted — an unknown enum value silently becoming `.local` would
/// repoint a repository without a word, and the next save would persist it.
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

    /// Reports one tolerant fallback to the bound note box, if there is one.
    /// Silent without a box — models decoded bare record nothing.
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
/// inside the `withValue` closure, so it never crosses an isolation
/// boundary; the lock exists only so the box can claim `Sendable`, which
/// binding a task-local value requires.
enum DecodeNotes {
    @TaskLocal static var current: DecodeNoteBox?

    /// A type-valid but out-of-range value decodes cleanly and then does
    /// harm; it is read as the nearest valid value, and the substitution is
    /// reported like every other one.
    static func clamped(_ value: Int, _ range: ClosedRange<Int>, _ field: String) -> Int {
        guard !range.contains(value) else { return value }
        let nearest = value < range.lowerBound ? range.lowerBound : range.upperBound
        current?.add(field: field, "\(value) is out of range — read as \(nearest)")
        return nearest
    }
}

final class DecodeNoteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(field: String, detail: String)] = []

    func add(field: String, _ detail: String) {
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
