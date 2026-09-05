import Foundation

/// Tolerant accessors for decoding the stored configuration.
///
/// The synthesized `Decodable` conformance requires every key to be present, so
/// a `config.json` written before a field existed fails to decode outright — and
/// for a backup app that means silently losing every schedule and repository the
/// user had set up. Every persisted model decodes through these instead, so an
/// unknown, missing or malformed field falls back to its default rather than
/// taking the whole document down with it.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded ?? fallback
    }

    func optional<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
